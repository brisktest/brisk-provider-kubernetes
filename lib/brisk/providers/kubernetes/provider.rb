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
