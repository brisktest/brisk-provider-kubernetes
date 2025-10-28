# frozen_string_literal: true

module Brisk
  module Providers
    module Kubernetes
      # Service for managing Kubernetes pods as Brisk workers
      class PodService
        attr_reader :project, :client

        def initialize(project, client)
          @project = project
          @client = client
        end

        # Get or create worker pods for a job run
        # @param jobrun [Jobrun] The job run
        # @param workers_needed [Integer] Number of workers needed
        # @return [Array<Worker>] Array of workers
        def get_workers_for_project(jobrun, workers_needed)
          namespace = project.provider_config['namespace'] || 'brisk-workers'

          # Find available workers (pods in Ready state)
          available_workers = find_available_workers(namespace)

          if available_workers.size >= workers_needed
            # Use existing workers
            available_workers.first(workers_needed)
          else
            # Create additional workers
            needed = workers_needed - available_workers.size
            Rails.logger.info "[K8s] Creating #{needed} new worker pods"

            new_workers = needed.times.map do
              create_worker_pod(default_machine_config)
            end

            available_workers + new_workers.compact
          end
        end

        # Create a worker pod
        # @param machine_config [Hash] Machine configuration
        # @return [Machine] The created machine
        def create_worker_pod(machine_config)
          namespace = project.provider_config['namespace'] || 'brisk-workers'
          pod_name = "brisk-worker-#{project.id}-#{SecureRandom.hex(4)}"

          pod_spec = build_pod_spec(pod_name, machine_config)

          Rails.logger.debug "[K8s] Creating pod: #{pod_name}"
          pod = client.api('v1').resource('pods', namespace: namespace).create_resource(pod_spec)

          # Wait for pod to get IP address (with timeout)
          pod = wait_for_pod_ip(namespace, pod_name, timeout: 30)

          # Create machine record
          machine = Machine.create!(
            uid: pod.metadata.name,
            provider: 'kubernetes',
            ip_address: pod.status.podIP,
            host_ip: pod.status.hostIP,
            state: 'running',
            config: machine_config,
            json_data: {
              namespace: namespace,
              pod_name: pod.metadata.name,
              node_name: pod.spec.nodeName
            }
          )

          Rails.logger.info "[K8s] Created pod #{pod_name} on node #{pod.spec.nodeName}"
          machine
        rescue K8s::Error::API => e
          Rails.logger.error "[K8s] Failed to create pod: #{e.message}"
          raise ::Providers::ProviderError, "Kubernetes API error: #{e.message}"
        end

        # Restart a pod (delete and recreate)
        # @param worker [Worker] The worker to restart
        # @return [Machine] The new machine
        def restart_pod(worker)
          namespace = worker.machine.json_data['namespace'] || 'brisk-workers'
          old_pod_name = worker.machine.uid

          # Delete old pod
          begin
            client.api('v1').resource('pods', namespace: namespace).delete(
              old_pod_name,
              propagationPolicy: 'Foreground'
            )
          rescue K8s::Error::NotFound
            # Already deleted, continue
          end

          # Create new pod
          create_worker_pod(worker.machine.config || default_machine_config)
        end

        private

        # Find available workers (free and in ready state)
        # @param namespace [String] Kubernetes namespace
        # @return [Array<Worker>] Available workers
        def find_available_workers(namespace)
          # Find all pods for this project
          pods = client.api('v1').resource('pods', namespace: namespace).list(
            labelSelector: "brisk-project-id=#{project.id},brisk-role=worker"
          )

          # Get workers from database that are free
          pod_uids = pods.map { |p| p.metadata.name }
          machines = project.machines.where(provider: 'kubernetes', uid: pod_uids)

          project.workers.free.not_stale.where(machine: machines).to_a
        end

        # Wait for pod to get an IP address
        # @param namespace [String] Kubernetes namespace
        # @param pod_name [String] Pod name
        # @param timeout [Integer] Timeout in seconds
        # @return [K8s::Resource] Pod with IP address
        def wait_for_pod_ip(namespace, pod_name, timeout: 30)
          deadline = Time.current + timeout

          loop do
            pod = client.api('v1').resource('pods', namespace: namespace).get(pod_name)

            if pod.status.podIP.present?
              return pod
            end

            if Time.current > deadline
              raise ::Providers::ProviderError, "Timeout waiting for pod IP: #{pod_name}"
            end

            sleep 1
          end
        rescue K8s::Error::NotFound
          raise ::Providers::ProviderError, "Pod not found: #{pod_name}"
        end

        # Build Kubernetes pod specification
        # @param pod_name [String] Pod name
        # @param machine_config [Hash] Machine configuration
        # @return [Hash] Pod specification
        def build_pod_spec(pod_name, machine_config)
          namespace = project.provider_config['namespace'] || 'brisk-workers'

          {
            apiVersion: 'v1',
            kind: 'Pod',
            metadata: {
              name: pod_name,
              namespace: namespace,
              labels: {
                'brisk-project-id' => project.id.to_s,
                'brisk-role' => 'worker',
                'app' => 'brisk-worker'
              },
              annotations: {
                'brisk.dev/project-name' => project.name,
                'brisk.dev/created-at' => Time.current.iso8601
              }
            },
            spec: {
              restartPolicy: 'Never',
              containers: [
                {
                  name: 'worker',
                  image: project.image.url,
                  imagePullPolicy: 'Always',
                  env: build_env_vars,
                  resources: build_resources(machine_config),
                  ports: [
                    { name: 'grpc', containerPort: 50051, protocol: 'TCP' },
                    { name: 'health', containerPort: 8081, protocol: 'TCP' }
                  ],
                  livenessProbe: {
                    httpGet: { path: '/health', port: 8081 },
                    initialDelaySeconds: 10,
                    periodSeconds: 30
                  },
                  readinessProbe: {
                    httpGet: { path: '/ready', port: 8081 },
                    initialDelaySeconds: 5,
                    periodSeconds: 10
                  }
                }
              ],
              # Optional: Use node selector for specific node pools
              nodeSelector: machine_config[:node_selector] || {},
              # Optional: Add tolerations for tainted nodes
              tolerations: machine_config[:tolerations] || []
            }
          }
        end

        # Build environment variables for worker container
        # @return [Array<Hash>] Environment variables
        def build_env_vars
          base_env = [
            { name: 'BRISK_PROJECT_ID', value: project.id.to_s },
            { name: 'BRISK_PROJECT_TOKEN', value: project.project_token },
            { name: 'BRISK_API_ENDPOINT', value: ENV['BRISK_API_ENDPOINT'] || 'api.brisk.dev:443' },
            { name: 'WORKER_CONCURRENCY', value: project.worker_concurrency.to_s }
          ]

          # Add custom environment variables from provider config
          custom_env = project.provider_config.fetch('env', {}).map do |key, value|
            { name: key.to_s, value: value.to_s }
          end

          base_env + custom_env
        end

        # Build resource requests and limits
        # @param machine_config [Hash] Machine configuration
        # @return [Hash] Resource specification
        def build_resources(machine_config)
          memory = machine_config[:memory_mb] || 4096
          cpu = machine_config[:cpu_count] || 2

          {
            requests: {
              memory: "#{memory}Mi",
              cpu: cpu.to_s
            },
            limits: {
              memory: "#{memory * 1.5}Mi", # Allow 50% burst
              cpu: (cpu * 1.5).to_s
            }
          }
        end

        # Default machine configuration
        # @return [Hash] Default configuration
        def default_machine_config
          {
            memory_mb: 4096,
            cpu_count: 2,
            node_selector: {},
            tolerations: []
          }
        end
      end
    end
  end
end
