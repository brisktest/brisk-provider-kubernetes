# Brisk Provider: Kubernetes

Run Brisk CI workers as Kubernetes pods in your cluster. This provider manages the full lifecycle of worker pods, from creation to cleanup.

## Features

- ✅ **Dynamic Pod Creation** - Automatically creates worker pods on-demand
- ✅ **Auto-scaling** - Works with Kubernetes Horizontal Pod Autoscaler
- ✅ **Health Management** - Uses Kubernetes liveness and readiness probes
- ✅ **Resource Limits** - Configurable CPU and memory requests/limits
- ✅ **Node Selection** - Support for node selectors and tolerations
- ✅ **Namespace Isolation** - Run workers in dedicated namespaces
- ✅ **Orphan Cleanup** - Automatic reconciliation of orphaned pods

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'brisk-provider-kubernetes'
```

Or install from source:

```ruby
gem 'brisk-provider-kubernetes', git: 'https://github.com/brisktest/brisk-provider-kubernetes'
```

Then execute:

```bash
bundle install
```

The provider will auto-register when Rails boots.

## Configuration

### Prerequisites

1. **Kubernetes Cluster** - You need a running Kubernetes cluster
2. **kubectl Access** - Configured kubeconfig or in-cluster service account
3. **Namespace** - Create a namespace for Brisk workers:

```bash
kubectl create namespace brisk-workers
```

### Environment Variables

**For local development (using kubeconfig):**
```bash
KUBECONFIG=/path/to/kubeconfig
K8S_NAMESPACE=brisk-workers  # Optional, defaults to brisk-workers
BRISK_API_ENDPOINT=api.brisk.dev:443
```

**For in-cluster deployment (using service account):**
```bash
K8S_NAMESPACE=brisk-workers  # Optional
BRISK_API_ENDPOINT=api.brisk.dev:443
```

### RBAC Permissions

The Brisk API needs these Kubernetes permissions:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: brisk-api
  namespace: brisk-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: brisk-worker-manager
  namespace: brisk-workers
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch", "create", "delete"]
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind:RoleBinding
metadata:
  name: brisk-api-worker-manager
  namespace: brisk-workers
subjects:
- kind: ServiceAccount
  name: brisk-api
  namespace: brisk-system
roleRef:
  kind: Role
  name: brisk-worker-manager
  apiGroup: rbac.authorization.k8s.io
```

Apply with:
```bash
kubectl apply -f rbac.yaml
```

### Project Configuration

Create a project using the Kubernetes provider:

```ruby
project = Project.create!(
  name: "My K8s Project",
  worker_provider: 'kubernetes',
  provider_config: {
    # Required
    'namespace' => 'brisk-workers',

    # Optional: Custom environment variables
    'env' => {
      'CUSTOM_VAR' => 'value',
      'DEBUG' => 'true'
    },

    # Optional: Resource defaults
    'default_memory_mb' => 4096,
    'default_cpu_count' => 2,

    # Optional: Node selection
    'node_selector' => {
      'workload-type' => 'ci'
    },

    # Optional: Tolerations for tainted nodes
    'tolerations' => [
      {
        'key' => 'ci-workload',
        'operator' => 'Equal',
        'value' => 'true',
        'effect' => 'NoSchedule'
      }
    ]
  }
)
```

## Usage

Once configured, the provider works automatically:

```ruby
# Start a test run
jobrun = project.jobruns.create!(/* ... */)

# Provider automatically:
# 1. Finds available worker pods
# 2. Creates new pods if needed
# 3. Allocates them to the jobrun
# 4. Cleans up after tests complete

# Check worker status
project.workers.in_use.each do |worker|
  puts "Worker #{worker.id}: #{worker.state}"
  puts "  Pod: #{worker.machine.uid}"
  puts "  Node: #{worker.machine.json_data['node_name']}"
end
```

## Pod Configuration

Worker pods are created with:

### Container Spec
- **Image**: From `project.image.url`
- **Ports**:
  - 50051 (gRPC for worker communication)
  - 8081 (HTTP for health checks)
- **Environment**:
  - `BRISK_PROJECT_ID`
  - `BRISK_PROJECT_TOKEN`
  - `BRISK_API_ENDPOINT`
  - `WORKER_CONCURRENCY`
  - Custom vars from `provider_config['env']`

### Resources
```yaml
resources:
  requests:
    memory: "4096Mi"  # Configurable
    cpu: "2"          # Configurable
  limits:
    memory: "6144Mi"  # 1.5x requests
    cpu: "3"          # 1.5x requests
```

### Health Checks
```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 8081
  initialDelaySeconds: 10
  periodSeconds: 30

readinessProbe:
  httpGet:
    path: /ready
    port: 8081
  initialDelaySeconds: 5
  periodSeconds: 10
```

### Labels
All pods are labeled with:
- `brisk-project-id: <project_id>`
- `brisk-role: worker`
- `app: brisk-worker`

Use these labels for monitoring, network policies, etc.

## Advanced Configuration

### Custom Resource Limits

```ruby
project.update!(
  provider_config: {
    'namespace' => 'brisk-workers',
    'default_memory_mb' => 8192,  # 8GB RAM
    'default_cpu_count' => 4       # 4 CPUs
  }
)
```

### Node Selection

Run workers on specific nodes:

```ruby
project.update!(
  provider_config: {
    'namespace' => 'brisk-workers',
    'node_selector' => {
      'workload-type' => 'ci',
      'disk-type' => 'ssd'
    }
  }
)
```

### Tolerations

Run on tainted nodes:

```ruby
project.update!(
  provider_config: {
    'namespace' => 'brisk-workers',
    'tolerations' => [
      {
        'key' => 'ci-workload',
        'operator' => 'Equal',
        'value' => 'true',
        'effect' => 'NoSchedule'
      }
    ]
  }
)
```

### Multiple Namespaces

Run different projects in different namespaces:

```ruby
# Project 1 - staging environment
project1 = Project.create!(
  name: "Staging Tests",
  worker_provider: 'kubernetes',
  provider_config: { 'namespace' => 'brisk-staging' }
)

# Project 2 - production environment
project2 = Project.create!(
  name: "Production Tests",
  worker_provider: 'kubernetes',
  provider_config: { 'namespace' => 'brisk-production' }
)
```

## Monitoring

### View Pods

```bash
# List all Brisk worker pods
kubectl get pods -n brisk-workers -l app=brisk-worker

# Watch pod status
kubectl get pods -n brisk-workers -l app=brisk-worker -w

# View logs
kubectl logs -n brisk-workers <pod-name>
```

### Metrics

Worker pods expose metrics on port 8081:
- `/health` - Liveness check
- `/ready` - Readiness check
- `/metrics` - Prometheus metrics (if enabled)

### Events

```bash
# View pod events
kubectl describe pod -n brisk-workers <pod-name>

# Watch events
kubectl get events -n brisk-workers -w
```

## Troubleshooting

### Pods Not Starting

Check events:
```bash
kubectl describe pod -n brisk-workers <pod-name>
```

Common issues:
- **ImagePullBackOff**: Check image URL and registry credentials
- **Pending**: Check resource requests vs available node capacity
- **CrashLoopBackOff**: Check pod logs for errors

### Workers Not Connecting

1. Check pod logs:
```bash
kubectl logs -n brisk-workers <pod-name>
```

2. Verify connectivity:
```bash
kubectl exec -n brisk-workers <pod-name> -- curl http://api.brisk.dev
```

3. Check environment variables:
```bash
kubectl exec -n brisk-workers <pod-name> -- env | grep BRISK
```

### Orphaned Pods

The provider automatically cleans up orphaned pods via reconciliation. To manually clean up:

```bash
# Delete all pods for a project
kubectl delete pods -n brisk-workers -l brisk-project-id=<project_id>

# Delete all Brisk worker pods
kubectl delete pods -n brisk-workers -l app=brisk-worker
```

## Development

### Running Tests

```bash
bundle exec rspec
```

### Testing Locally

1. Start minikube or kind cluster
2. Configure kubeconfig
3. Add gem to Gemfile with `path:` option
4. Create test project with `worker_provider: 'kubernetes'`

### Debugging

Enable debug logging:

```ruby
# config/environments/development.rb
Rails.logger.level = :debug
```

View provider logs:
```ruby
Rails.logger.tagged("K8s Provider") do
  # Provider operations will be logged
end
```

## Architecture

### Provider → PodService → Kubernetes API

```
Provider (provider.rb)
  └─> PodService (pod_service.rb)
      └─> K8s Client (k8s-ruby gem)
          └─> Kubernetes API
```

### Pod Lifecycle

1. **Creation**: Provider creates pod via PodService
2. **Registration**: Pod starts and registers via gRPC
3. **Allocation**: Worker is allocated to jobrun
4. **Execution**: Tests run on worker
5. **Cleanup**: Pod is deleted after job completes

### Health Management

- Kubernetes manages pod health via probes
- Brisk disables internal health tracking (sets `last_checked_at` to far future)
- Dead pods are automatically restarted by Kubernetes

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/brisktest/brisk-provider-kubernetes.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Support

- Documentation: https://docs.brisk.dev/providers/kubernetes
- Issues: https://github.com/brisktest/brisk-provider-kubernetes/issues
- Discussions: https://github.com/brisktest/brisk/discussions
