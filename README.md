# Brisk Provider: Kubernetes

Run Brisk CI workers as Kubernetes pods in your cluster. Workers are managed by a Kubernetes Deployment and self-register with the Brisk API via gRPC. This provider handles reconciliation and supervisor lifecycle — **not** individual pod creation.

## Features

- ✅ **Self-Registration** — Worker pods register themselves via gRPC on startup
- ✅ **Deployment-Managed Pods** — Kubernetes Deployment controls pod lifecycle and scaling
- ✅ **Ghost Worker Reconciliation** — Detects and cleans up workers whose pods have disappeared
- ✅ **Health Delegation** — Kubernetes probes manage pod health; Brisk skips internal health tracking
- ✅ **Namespace Isolation** — Run workers in dedicated namespaces
- ✅ **Supervisor Management** — Lightweight supervisor lifecycle (pods always running)
- ✅ **Auto-Registration** — Provider auto-registers via Rails Engine when gem is loaded

## Architecture

```
brisk-provider-kubernetes/
├── lib/brisk/providers/kubernetes/
│   ├── provider.rb      # Provider implementation (inherits BaseProvider)
│   ├── kube_client.rb   # Lightweight in-cluster K8s API client
│   └── engine.rb        # Rails Engine for auto-registration
├── examples/
│   ├── kubernetes-rbac.yaml
│   └── project-configuration.rb
└── spec/
```

### Provider → KubeClient → Kubernetes API

```
Provider (provider.rb)
  └─> KubeClient (kube_client.rb)
      └─> Kubernetes API (in-cluster, service account auth)
```

`KubeClient` is a lightweight HTTP client that uses the pod's service account token (`/var/run/secrets/kubernetes.io/serviceaccount/token`) to authenticate. It only supports read operations needed for reconciliation (listing pods).

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

The provider auto-registers when Rails boots via the Engine initializer.

## Configuration

### Prerequisites

1. **Kubernetes Cluster** — A running cluster with a worker Deployment
2. **In-Cluster Access** — The Brisk API must run as a pod with a service account
3. **Namespace** — Create a namespace for Brisk workers:

```bash
kubectl create namespace brisk-staging
```

### Environment Variables

```bash
K8S_NAMESPACE=brisk-staging        # Optional, defaults to brisk-staging
BRISK_API_ENDPOINT=api.brisk.dev:443
```

### RBAC Permissions

The Brisk API pod needs read access to worker pods for reconciliation:

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
  namespace: brisk-staging
rules:
# Required for reconciliation (KubeClient.list_pods)
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
# Optional: for debugging
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: brisk-api-worker-manager
  namespace: brisk-staging
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

See `examples/kubernetes-rbac.yaml` for a complete RBAC configuration including NetworkPolicy and ResourceQuota.

### Project Configuration

```ruby
project = Project.create!(
  name: "My K8s Project",
  worker_provider: 'kubernetes',
  provider_config: {
    # Namespace where worker pods run (default: brisk-staging)
    'namespace' => 'brisk-staging',

    # Label selector for finding worker pods (default: app=worker)
    'pod_label_selector' => 'app=worker'
  }
)
```

See `examples/project-configuration.rb` for advanced configuration examples.

## Worker Lifecycle

Workers are **not** created by this provider. They are managed by a Kubernetes Deployment and self-register with Brisk.

```
K8s Deployment creates pod
  → Pod starts and self-registers via gRPC
    → Worker record created in DB
      → Worker allocated to jobrun
        → Tests execute
          → Worker freed
            → Pod stays running (managed by Deployment)
```

### Key Differences from Other Providers

| Operation | Fly.io / Self-Hosted | Kubernetes |
|-----------|---------------------|------------|
| `create_worker` | Creates a machine/pod | **Raises `UnsupportedOperationError`** |
| `start_worker` | Starts the machine | Logs only (Deployment manages) |
| `stop_worker` | Stops the machine | Logs only (Deployment manages) |
| `destroy_worker` | Destroys the machine | De-registers the worker record |
| Scaling | Provider manages | `kubectl scale deployment` |

### Scaling Workers

```bash
# Scale up workers
kubectl scale deployment brisk-worker -n brisk-staging --replicas=10

# Scale down
kubectl scale deployment brisk-worker -n brisk-staging --replicas=2
```

## Supervisor Management

Supervisor pods in Kubernetes are always running (managed by a Deployment), so supervisor lifecycle is lightweight:

```ruby
claim_supervisor(supervisor)         # Logs that pod is always running
release_supervisor(supervisor)       # Clears in_use
cleanup_supervisor(supervisor)       # Logs that lifecycle is K8s-managed
after_supervisor_released(supervisor) # Inherited: frees workers still assigned
```

Since pods are always running, there is no need to start/stop/suspend machines. The base class `after_supervisor_released` hook frees any workers still assigned to the supervisor.

## Reconciliation

The `reconcile_workers` method syncs Kubernetes pod state with the Brisk database. It runs periodically via `ReconcileWorkersJob`.

### How It Works

1. **Check environment** — Only runs when `KubeClient.in_cluster?` is true (service account token exists)
2. **List pods** — Queries K8s API for running pods in the configured namespace with the configured label selector
3. **Compare with DB** — Finds workers in DB whose pods no longer exist
4. **Free ghost workers** — Workers reserved >5 minutes ago with missing pods are freed via `free_from_super`
5. **De-register stale workers** — Workers freed >10 minutes ago with missing pods are de-registered (state → `finished`)
6. **Error handling** — K8s API errors are caught gracefully; individual worker errors don't halt reconciliation

### Thresholds

| Condition | Threshold | Action |
|-----------|-----------|--------|
| Busy worker, pod gone | Reserved >5 min ago | `free_from_super` |
| Free worker, pod gone | Freed >10 min ago | `de_register!` |

## Provider Methods Reference

### Worker Management

```ruby
get_workers_for_project(jobrun)  # Delegates to ProjectService
create_worker(machine_config)    # Raises UnsupportedOperationError
start_worker(worker)             # Logs only
stop_worker(worker)              # Logs only
suspend_worker(worker)           # Logs only
destroy_worker(worker)           # De-registers worker
reconcile_workers                # Syncs pod state with DB
```

### Supervisor Management

```ruby
claim_supervisor(supervisor)           # Logs (pod always running)
release_supervisor(supervisor)         # Clears in_use
cleanup_supervisor(supervisor)         # Logs (K8s manages lifecycle)
after_supervisor_released(supervisor)  # Frees remaining workers (inherited)
```

### Configuration & Capabilities

```ruby
supports?(:self_registration)          # => true
supports?(:anything_else)              # => false
should_track_health?(worker)           # => false (K8s probes handle it)
register_worker_metadata(worker, params) # Sets last_checked_at to 10 years ahead
manages_machine?(machine)              # machine.provider == 'kubernetes'
provider_log_prefix                    # => 'K8s'
```

### Health Management

- Kubernetes manages pod health via liveness/readiness probes
- `should_track_health?` returns `false` — Brisk skips internal health checks
- `register_worker_metadata` sets `last_checked_at` to 10 years in the future to prevent Brisk's health checker from flagging K8s workers as stale

## Recommended Deployment Configuration

Worker pods should be configured in your Kubernetes Deployment with:

### Container Spec
- **Ports:**
  - 50051 (gRPC for worker communication)
  - 8081 (HTTP for health checks)
- **Environment:**
  - `BRISK_PROJECT_ID`
  - `BRISK_PROJECT_TOKEN`
  - `BRISK_API_ENDPOINT`
  - `WORKER_CONCURRENCY`

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
Ensure pods have labels matching your `pod_label_selector` (default: `app=worker`):
```yaml
metadata:
  labels:
    app: worker
```

## Advanced Configuration

### Custom Pod Selector

If your worker pods use different labels:

```ruby
project.update!(
  provider_config: {
    'namespace' => 'brisk-staging',
    'pod_label_selector' => 'role=brisk-worker,env=staging'
  }
)
```

### Multiple Namespaces

Run different projects in different namespaces:

```ruby
project1 = Project.create!(
  name: "Staging Tests",
  worker_provider: 'kubernetes',
  provider_config: { 'namespace' => 'brisk-staging' }
)

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
kubectl get pods -n brisk-staging -l app=worker

# Watch pod status
kubectl get pods -n brisk-staging -l app=worker -w

# View logs
kubectl logs -n brisk-staging <pod-name>
```

### Metrics

Worker pods expose metrics on port 8081:
- `/health` — Liveness check
- `/ready` — Readiness check
- `/metrics` — Prometheus metrics (if enabled)

### Events

```bash
kubectl describe pod -n brisk-staging <pod-name>
kubectl get events -n brisk-staging -w
```

## Troubleshooting

### Pods Not Starting

```bash
kubectl describe pod -n brisk-staging <pod-name>
```

Common issues:
- **ImagePullBackOff**: Check image URL and registry credentials
- **Pending**: Check resource requests vs available node capacity
- **CrashLoopBackOff**: Check pod logs for startup errors

### Workers Not Connecting

1. Check pod logs:
```bash
kubectl logs -n brisk-staging <pod-name>
```

2. Verify connectivity to the Brisk API:
```bash
kubectl exec -n brisk-staging <pod-name> -- curl http://api.brisk.dev
```

3. Check environment variables:
```bash
kubectl exec -n brisk-staging <pod-name> -- env | grep BRISK
```

### Ghost Workers in DB

If workers appear in the database but their pods are gone, reconciliation will clean them up automatically. To trigger manually:

```ruby
project.provider.reconcile_workers
```

### Reconciliation Not Running

Reconciliation only runs when the Brisk API is deployed **inside** the Kubernetes cluster (checks for service account token at `/var/run/secrets/kubernetes.io/serviceaccount/token`). It will skip silently when running outside the cluster.

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

Provider logs are prefixed with `[K8s]`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/brisktest/brisk-provider-kubernetes.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Support

- Documentation: https://docs.brisk.dev/providers/kubernetes
- Issues: https://github.com/brisktest/brisk-provider-kubernetes/issues
- Discussions: https://github.com/brisktest/brisk/discussions

