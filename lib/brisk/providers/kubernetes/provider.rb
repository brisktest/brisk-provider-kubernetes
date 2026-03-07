# frozen_string_literal: true

require "cgi"
require "json"
require "net/http"
require "openssl"

module Brisk
  module Providers
    module Kubernetes
      # Kubernetes-aware infrastructure provider
      # Workers run as pods in the same cluster and self-register via gRPC.
      # This provider adds auto-healing: before each worker allocation it checks
      # the actual K8s pod status and resets any DB records that are stuck in a
      # bad state (finished, freed_at nil, etc.) while the pod is still healthy.
      class Provider < ::Providers::BaseProvider
        K8S_API_HOST = "https://kubernetes.default.svc"
        TOKEN_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/token"
        CA_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
        NAMESPACE_PATH = "/var/run/secrets/kubernetes.io/serviceaccount/namespace"

        def get_workers_for_project(jobrun)
          heal_stuck_workers(jobrun)
          ProjectService.get_workers_for_project(jobrun)
        end

        def create_worker(_machine_config)
          raise ::Providers::UnsupportedOperationError,
                "Kubernetes workers are managed by the cluster Deployment. Scale the workers Deployment instead."
        end

        def start_worker(worker)
          Rails.logger.info "[K8s] Cannot start worker #{worker.id} individually - managed by Deployment"
        end

        def stop_worker(worker)
          Rails.logger.info "[K8s] Cannot stop worker #{worker.id} individually - managed by Deployment"
        end

        def suspend_worker(worker)
          Rails.logger.info "[K8s] Suspend not supported for Kubernetes workers"
        end

        def destroy_worker(worker)
          worker.de_register! unless worker.finished?
          Rails.logger.info "[K8s] Worker #{worker.id} de-registered"
        end

        def reconcile_workers
          Rails.logger.info "[K8s] Reconciling workers for project #{project.id}"
          heal_stuck_workers(nil)
          Rails.logger.info "[K8s] Reconciliation complete for project #{project.id}"
        end

        def supports?(feature)
          case feature
          when :self_registration then true
          else false
          end
        end

        def after_worker_allocated(workers)
          Rails.logger.debug "[K8s] #{workers.size} workers allocated"
          project.balance_workers
        end

        def after_worker_freed(worker)
          Rails.logger.debug "[K8s] Worker #{worker.id} freed"
        end

        def should_track_health?(_worker)
          false # K8s manages pod health via probes
        end

        def register_worker_metadata(_worker, _params)
          { last_checked_at: 10.years.from_now }
        end

        def manages_machine?(machine)
          machine.provider == "kubernetes" || machine.provider.blank?
        end

        private

        # Core auto-healing: check K8s pod health and reset stuck DB records
        def heal_stuck_workers(jobrun)
          Rails.logger.info "[K8s] Checking for stuck workers to heal"

          running_pod_ips = fetch_running_pod_ips
          if running_pod_ips.nil?
            Rails.logger.warn "[K8s] Could not fetch pod status from K8s API, skipping heal"
            return
          end

          Rails.logger.info "[K8s] Found #{running_pod_ips.size} running worker pods: #{running_pod_ips}"

          healed = 0
          worker_image = jobrun&.worker_image || project.image&.name

          # Find workers that are stuck (not usable by the normal scopes)
          stuck_workers = project.workers
                                 .where.not(state: "active")
                                 .or(project.workers.where(freed_at: nil))

          stuck_workers.includes(:machine).each do |worker|
            next unless worker.machine

            pod_ip = worker.ip_address || worker.machine.ip_address
            next unless running_pod_ips.include?(pod_ip)

            # Pod is healthy but worker record is stuck - reset it
            if worker.state == "finished" || (worker.state == "assigned" && worker.freed_at.nil? && worker.jobrun_id.present?)
              Rails.logger.info "[K8s] Healing stuck worker #{worker.id}: state=#{worker.state} freed_at=#{worker.freed_at} jobrun=#{worker.jobrun_id}"

              worker.update_columns(
                state: "active",
                freed_at: Time.current,
                supervisor_id: nil,
                jobrun_id: nil,
                assigned_ram: 0,
                reserved_at: nil,
                last_checked_at: 10.years.from_now
              )
              healed += 1
            elsif worker.last_checked_at.present? && worker.last_checked_at < 2.minutes.ago
              # Worker is active but marked stale even though pod is running
              Rails.logger.info "[K8s] Refreshing stale worker #{worker.id}: last_checked_at=#{worker.last_checked_at}"
              worker.update_columns(last_checked_at: 10.years.from_now)
              healed += 1
            end
          end

          # Also heal workers with no project that match (unassigned workers)
          if worker_image
            unassigned_stuck = Worker.where(project_id: nil)
                                     .where(state: "finished")
                                     .with_worker_image(worker_image)

            unassigned_stuck.includes(:machine).each do |worker|
              next unless worker.machine

              pod_ip = worker.ip_address || worker.machine.ip_address
              next unless running_pod_ips.include?(pod_ip)

              Rails.logger.info "[K8s] Healing stuck unassigned worker #{worker.id}"
              worker.update_columns(
                state: "active",
                freed_at: Time.current,
                supervisor_id: nil,
                jobrun_id: nil,
                assigned_ram: 0,
                reserved_at: nil,
                last_checked_at: 10.years.from_now
              )
              healed += 1
            end
          end

          Rails.logger.info "[K8s] Healed #{healed} stuck workers" if healed > 0
        rescue StandardError => e
          Rails.logger.error "[K8s] Error during heal_stuck_workers: #{e.message}"
          Rails.logger.error e.backtrace&.first(5)&.join("\n")
          # Don't fail the whole request - just skip healing
        end

        # Query K8s API for running worker pod IPs
        def fetch_running_pod_ips
          namespace = k8s_namespace
          label_selector = pod_label_selector

          uri = URI("#{K8S_API_HOST}/api/v1/namespaces/#{namespace}/pods?labelSelector=#{CGI.escape(label_selector)}")

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true

          if File.exist?(CA_PATH)
            http.ca_file = CA_PATH
            http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          else
            http.verify_mode = OpenSSL::SSL::VERIFY_NONE
          end

          request = Net::HTTP::Get.new(uri)
          request["Authorization"] = "Bearer #{k8s_token}"
          request["Accept"] = "application/json"

          response = http.request(request)

          unless response.is_a?(Net::HTTPSuccess)
            Rails.logger.error "[K8s] API request failed: #{response.code} #{response.body&.first(200)}"
            return nil
          end

          data = JSON.parse(response.body)
          pods = data["items"] || []

          running_ips = pods.filter_map do |pod|
            phase = pod.dig("status", "phase")
            pod_ip = pod.dig("status", "podIP")

            if phase == "Running" && pod_ip.present?
              pod_ip
            end
          end

          running_ips
        rescue StandardError => e
          Rails.logger.error "[K8s] Failed to fetch pod IPs: #{e.class} #{e.message}"
          nil
        end

        def k8s_token
          @k8s_token ||= if File.exist?(TOKEN_PATH)
                            File.read(TOKEN_PATH).strip
                          else
                            ENV["K8S_TOKEN"]
                          end
        end

        def k8s_namespace
          @k8s_namespace ||= project.provider_config&.dig("namespace") ||
                             (File.exist?(NAMESPACE_PATH) ? File.read(NAMESPACE_PATH).strip : nil) ||
                             ENV["K8S_NAMESPACE"] ||
                             "brisk-staging"
        end

        def pod_label_selector
          project.provider_config&.dig("pod_label_selector") || "app=worker"
        end
      end
    end
  end
end
