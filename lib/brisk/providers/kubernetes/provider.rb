# frozen_string_literal: true

require 'k8s-ruby'

module Brisk
  module Providers
    module Kubernetes
      # Kubernetes provider for Brisk
      # Manages workers as Kubernetes pods in a cluster
      class Provider < ::Providers::BaseProvider
        TRACER = defined?(MyAppTracer) ? MyAppTracer : nil

        # Get workers for a project by finding available pods
        # @param jobrun [Jobrun] The job run requesting workers
        # @return [Array<Worker>] Array of allocated workers
        def get_workers_for_project(jobrun)
          workers_needed = project.worker_concurrency
          Rails.logger.info "[K8s] Getting #{workers_needed} workers for jobrun #{jobrun.id}"

          service = Brisk::Providers::Kubernetes::PodService.new(project, k8s_client)
          service.get_workers_for_project(jobrun, workers_needed)
        end

        # Create a new worker pod
        # @param machine_config [Hash] Machine configuration
        # @return [Machine] The created machine record
        def create_worker(machine_config)
          validate_config!

          Rails.logger.info "[K8s] Creating worker pod with config: #{machine_config}"

          service = Brisk::Providers::Kubernetes::PodService.new(project, k8s_client)
          service.create_worker_pod(machine_config)
        rescue K8s::Error::API => e
          raise ::Providers::ProviderError, "Failed to create Kubernetes pod: #{e.message}"
        end

        # Start a worker pod (scale from 0 or unpause)
        # @param worker [Worker] The worker to start
        def start_worker(worker)
          Rails.logger.info "[K8s] Starting worker #{worker.id}"

          pod_name = worker.machine.uid
          namespace = k8s_namespace

          # If pod is paused, resume it
          # Otherwise, ensure it's running
          client = k8s_client
          pod = client.api('v1').resource('pods', namespace: namespace).get(pod_name)

          unless pod.status.phase == 'Running'
            # Restart pod by deleting and recreating
            service = Brisk::Providers::Kubernetes::PodService.new(project, client)
            service.restart_pod(worker)
          end
        rescue K8s::Error::NotFound
          Rails.logger.warn "[K8s] Pod #{pod_name} not found, recreating"
          create_worker(worker.machine.config)
        rescue K8s::Error::API => e
          raise ::Providers::ProviderError, "Failed to start pod: #{e.message}"
        end

        # Stop a worker pod (scale to 0 but preserve definition)
        # @param worker [Worker] The worker to stop
        def stop_worker(worker)
          Rails.logger.info "[K8s] Stopping worker #{worker.id}"

          pod_name = worker.machine.uid
          namespace = k8s_namespace

          # Delete the pod (deployment will handle recreation if needed)
          client = k8s_client
          client.api('v1').resource('pods', namespace: namespace).delete(pod_name, propagationPolicy: 'Foreground')

          worker.machine.update(state: 'stopped')
        rescue K8s::Error::NotFound
          Rails.logger.warn "[K8s] Pod #{pod_name} already deleted"
        rescue K8s::Error::API => e
          raise ::Providers::ProviderError, "Failed to stop pod: #{e.message}"
        end

        # Suspend a worker pod (not supported, falls back to stop)
        # @param worker [Worker] The worker to suspend
        def suspend_worker(worker)
          Rails.logger.info "[K8s] Suspending worker #{worker.id} (using stop)"
          stop_worker(worker)
        end

        # Destroy a worker pod permanently
        # @param worker [Worker] The worker to destroy
        def destroy_worker(worker)
          Rails.logger.info "[K8s] Destroying worker #{worker.id}"

          pod_name = worker.machine.uid
          namespace = k8s_namespace

          client = k8s_client
          client.api('v1').resource('pods', namespace: namespace).delete(
            pod_name,
            propagationPolicy: 'Foreground',
            gracePeriodSeconds: 30
          )

          worker.machine.update(state: 'terminated', finished_at: Time.current)
        rescue K8s::Error::NotFound
          Rails.logger.warn "[K8s] Pod #{pod_name} already deleted"
        rescue K8s::Error::API => e
          Rails.logger.error "[K8s] Failed to destroy pod: #{e.message}"
          # Continue even if deletion fails
        end

        # Reconcile workers - clean up orphaned pods
        def reconcile_workers
          Rails.logger.info "[K8s] Reconciling workers for project #{project.id}"

          namespace = k8s_namespace
          client = k8s_client

          # Find all pods with project label
          pods = client.api('v1').resource('pods', namespace: namespace).list(
            labelSelector: "brisk-project-id=#{project.id},brisk-role=worker"
          )

          # Get all known machines
          known_uids = project.machines.where(provider: 'kubernetes').pluck(:uid)

          # Delete orphaned pods
          orphaned = pods.select { |pod| !known_uids.include?(pod.metadata.name) }
          orphaned.each do |pod|
            Rails.logger.info "[K8s] Deleting orphaned pod: #{pod.metadata.name}"
            client.api('v1').resource('pods', namespace: namespace).delete(
              pod.metadata.name,
              propagationPolicy: 'Background'
            )
          end

          Rails.logger.info "[K8s] Reconciliation complete: #{orphaned.size} orphaned pods deleted"
        rescue K8s::Error::API => e
          Rails.logger.error "[K8s] Reconciliation failed: #{e.message}"
        end

        # Feature support
        # @param feature [Symbol] Feature name
        # @return [Boolean] Whether feature is supported
        def supports?(feature)
          case feature
          when :dynamic_creation
            true # Can create pods on-demand
          when :suspend
            false # Kubernetes doesn't have suspend, we stop instead
          when :auto_scale
            true # Can use HPA (Horizontal Pod Autoscaler)
          when :spot_instances
            false # Not applicable to Kubernetes
          else
            false
          end
        end

        # Called after workers are allocated
        # @param workers [Array<Worker>] Allocated workers
        def after_worker_allocated(workers)
          Rails.logger.debug "[K8s] #{workers.size} workers allocated, no balancing needed"
          # Kubernetes handles scheduling and balancing
        end

        # Called after a worker is freed
        # @param worker [Worker] The freed worker
        def after_worker_freed(worker)
          Rails.logger.info "[K8s] Scheduling cleanup for worker #{worker.id}"
          # Schedule cleanup after a delay to allow for reuse
          # CleanupKubernetesWorkerJob.set(wait: 5.minutes).perform_later(worker.id)

          # For now, just log - pods will be cleaned up by reconciliation
        end

        # Should Brisk track health for this worker?
        # Kubernetes manages pod health via liveness/readiness probes
        # @param worker [Worker] The worker
        # @return [Boolean] false - Kubernetes manages health
        def should_track_health?(worker)
          false
        end

        # Register worker metadata when worker registers via gRPC
        # @param worker [Worker] The worker
        # @param params [Hash] Registration parameters
        # @return [Hash] Metadata to set on worker
        def register_worker_metadata(worker, params)
          {
            last_checked_at: 10.years.from_now # Kubernetes manages health
          }
        end

        # Does this provider manage this machine?
        # @param machine [Machine] The machine
        # @return [Boolean] true if machine is a Kubernetes pod
        def manages_machine?(machine)
          machine.provider == "kubernetes"
        end

        private

        # Get Kubernetes client
        # @return [K8s::Client] Kubernetes client
        def k8s_client
          @k8s_client ||= begin
            config = k8s_config
            K8s::Client.config(config)
          end
        end

        # Get Kubernetes configuration
        # @return [K8s::Config] Kubernetes configuration
        def k8s_config
          # Try in-cluster config first (for running inside Kubernetes)
          if in_cluster?
            K8s::Config.load_file('/var/run/secrets/kubernetes.io/serviceaccount/token')
          else
            # Use kubeconfig for local development
            kubeconfig_path = ENV['KUBECONFIG'] || File.expand_path('~/.kube/config')
            K8s::Config.load_file(kubeconfig_path)
          end
        rescue StandardError => e
          raise ::Providers::ConfigurationError, "Failed to load Kubernetes config: #{e.message}"
        end

        # Check if running inside Kubernetes cluster
        # @return [Boolean] true if running in-cluster
        def in_cluster?
          File.exist?('/var/run/secrets/kubernetes.io/serviceaccount/token')
        end

        # Get Kubernetes namespace for this project
        # @return [String] Namespace name
        def k8s_namespace
          project.provider_config['namespace'] || ENV['K8S_NAMESPACE'] || 'brisk-workers'
        end

        # Validate provider configuration
        # @raise [Providers::ConfigurationError] if configuration is invalid
        def validate_config!
          # Ensure namespace exists or can be created
          namespace = k8s_namespace

          unless namespace.present?
            raise ::Providers::ConfigurationError, "Kubernetes namespace not configured"
          end

          # Validate image is configured
          unless project.image&.url.present?
            raise ::Providers::ConfigurationError, "Worker image not configured"
          end
        end
      end
    end
  end
end
