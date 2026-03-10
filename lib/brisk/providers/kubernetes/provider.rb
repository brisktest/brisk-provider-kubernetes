# frozen_string_literal: true

require_relative 'kube_client'

module Brisk
  module Providers
    module Kubernetes
      # Kubernetes provider for Brisk CI
      # Workers run as pods managed by a Deployment in the same cluster
      # and self-register via gRPC. This provider does not manage individual
      # pod lifecycle — Kubernetes handles that.
      class Provider < ::Providers::BaseProvider
        def get_workers_for_project(jobrun)
          ProjectService.get_workers_for_project(jobrun)
        end

        def create_worker(_machine_config)
          raise ::Providers::UnsupportedOperationError,
                'Kubernetes workers are managed by the cluster Deployment. Scale the workers Deployment instead.'
        end

        def start_worker(worker)
          Rails.logger.info "[K8s] Cannot start worker #{worker.id} individually - managed by Deployment"
        end

        def stop_worker(worker)
          Rails.logger.info "[K8s] Cannot stop worker #{worker.id} individually - managed by Deployment"
        end

        def suspend_worker(_worker)
          Rails.logger.info '[K8s] Suspend not supported for Kubernetes workers'
        end

        def destroy_worker(worker)
          worker.de_register! unless worker.finished?
          Rails.logger.info "[K8s] Worker #{worker.id} de-registered"
        end

        def reconcile_workers
          unless KubeClient.in_cluster?
            Rails.logger.info '[K8s] Not running in a Kubernetes cluster, skipping reconciliation'
            return
          end

          namespace = resolve_namespace
          Rails.logger.info "[K8s] Reconciling workers for project #{project.id} in namespace #{namespace}"

          begin
            client = KubeClient.new
            pods = client.list_pods(namespace: namespace, label_selector: resolve_pod_selector)
          rescue KubeApiError => e
            Rails.logger.warn "[K8s] Cannot reconcile — K8s API unavailable: #{e.message}"
            return
          end

          running_pod_names = Set.new(
            pods.reject { |p| %w[Failed Succeeded].include?(p[:status]) }
                .map { |p| p[:name] }
          )

          k8s_workers = project.workers
                               .where.not(state: 'finished')
                               .joins(:machine)
                               .where(machines: { provider: 'kubernetes' })
                               .includes(:machine)

          ghost_freed = 0
          stale_deregistered = 0

          k8s_workers.each do |worker|
            next if worker.machine.nil?
            next if running_pod_names.include?(worker.machine.uid)

            if worker.freed_at.nil? && worker.reserved_at.present? && worker.reserved_at < 5.minutes.ago
              Rails.logger.info "[K8s] Freeing ghost worker #{worker.id} (pod #{worker.machine.uid} not found)"
              worker.free_from_super
              ghost_freed += 1
            elsif worker.freed_at.present? && worker.freed_at < 10.minutes.ago
              Rails.logger.info "[K8s] De-registering stale worker #{worker.id} (pod #{worker.machine.uid} not found)"
              worker.de_register! unless worker.finished?
              stale_deregistered += 1
            end
          rescue StandardError => e
            Rails.logger.error "[K8s] Error reconciling worker #{worker.id}: #{e.message}"
          end

          Rails.logger.info "[K8s] Reconciliation complete for project #{project.id}: " \
                            "freed #{ghost_freed} ghost workers, de-registered #{stale_deregistered} stale workers"
        end

        def supports?(feature)
          case feature
          when :self_registration then true
          else false
          end
        end

        def after_worker_allocated(workers)
          Rails.logger.debug "[K8s] #{workers.size} workers allocated, pod count managed by Deployment"
        end

        def claim_supervisor(supervisor)
          Rails.logger.debug "[K8s] Supervisor #{supervisor.id} claimed, pod is always running"
        end

        def release_supervisor(supervisor)
          supervisor.in_use = nil
        end

        def provider_log_prefix
          'K8s'
        end

        def cleanup_supervisor(supervisor)
          Rails.logger.debug "[K8s] Supervisor #{supervisor.id} de-registered, pod lifecycle managed by Kubernetes"
        end

        def after_worker_freed(worker)
          Rails.logger.debug "[K8s] Worker #{worker.id} freed"
        end

        def should_track_health?(_worker)
          false
        end

        def register_worker_metadata(_worker, _params)
          { last_checked_at: 10.years.from_now }
        end

        def manages_machine?(machine)
          machine.provider == 'kubernetes'
        end

        private

        def resolve_namespace
          (project.provider_config || {})['namespace'] ||
            ENV.fetch('K8S_NAMESPACE', 'brisk-staging')
        end

        def resolve_pod_selector
          (project.provider_config || {})['pod_label_selector'] || 'app=worker'
        end
      end
    end
  end
end
