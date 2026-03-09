# frozen_string_literal: true

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
          Rails.logger.info "[K8s] Reconciliation is handled by Kubernetes - no action needed"
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

        def claim_supervisor(supervisor)
          Rails.logger.debug "[K8s] Supervisor #{supervisor.id} claimed, pod is always running"
        end

        def release_supervisor(supervisor)
          supervisor.in_use = nil
        end

        def after_supervisor_released(supervisor)
          # Free any workers still assigned to this supervisor as a safety net.
          # Workers are normally freed during log_run, but this handles edge cases
          # (e.g., worker log_run failed, or worker was stuck in assigned state).
          # Runs outside the supervisor transaction to avoid nested locking.
          supervisor.workers.where(freed_at: nil).each do |worker|
            worker.free_from_super
          rescue => e
            Rails.logger.error "[K8s] Failed to free worker #{worker.id} during supervisor release: #{e.message}"
          end
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
          machine.provider == "kubernetes" || machine.provider.blank?
        end
      end
    end
  end
end
