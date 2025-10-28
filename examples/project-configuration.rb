# frozen_string_literal: true

# Example project configurations for Kubernetes provider

# Basic configuration with defaults
Project.create!(
  name: 'Basic K8s Project',
  framework: 'Jest',
  worker_provider: 'kubernetes',
  worker_concurrency: 5,
  provider_config: {
    'namespace' => 'brisk-workers'
  }
)

# Advanced configuration with custom resources
Project.create!(
  name: 'Advanced K8s Project',
  framework: 'RSpec',
  worker_provider: 'kubernetes',
  worker_concurrency: 10,
  provider_config: {
    # Namespace
    'namespace' => 'brisk-production',

    # Resource configuration
    'default_memory_mb' => 8192, # 8GB RAM per worker
    'default_cpu_count' => 4, # 4 CPUs per worker

    # Custom environment variables
    'env' => {
      'NODE_ENV' => 'test',
      'DATABASE_URL' => 'postgresql://test:test@db:5432/test',
      'REDIS_URL' => 'redis://redis:6379/0',
      'DEBUG' => 'true'
    },

    # Node selection - run on specific node pools
    'node_selector' => {
      'workload-type' => 'ci',
      'disk-type' => 'ssd',
      'instance-type' => 'cpu-optimized'
    },

    # Tolerations - allow scheduling on tainted nodes
    'tolerations' => [
      {
        'key' => 'ci-workload',
        'operator' => 'Equal',
        'value' => 'true',
        'effect' => 'NoSchedule'
      },
      {
        'key' => 'spot-instance',
        'operator' => 'Exists',
        'effect' => 'NoSchedule'
      }
    ]
  }
)

# GPU-enabled workers
Project.create!(
  name: 'GPU ML Tests',
  framework: 'Python',
  worker_provider: 'kubernetes',
  worker_concurrency: 2,
  provider_config: {
    'namespace' => 'brisk-ml',
    'default_memory_mb' => 16_384, # 16GB RAM
    'default_cpu_count' => 8,

    # Select GPU nodes
    'node_selector' => {
      'gpu' => 'nvidia-tesla-t4'
    },

    # Tolerate GPU node taints
    'tolerations' => [
      {
        'key' => 'nvidia.com/gpu',
        'operator' => 'Exists',
        'effect' => 'NoSchedule'
      }
    ],

    'env' => {
      'CUDA_VISIBLE_DEVICES' => '0',
      'GPU_MEMORY_FRACTION' => '0.8'
    }
  }
)

# High-memory workers for integration tests
Project.create!(
  name: 'Integration Tests',
  framework: 'Rails',
  worker_provider: 'kubernetes',
  worker_concurrency: 3,
  provider_config: {
    'namespace' => 'brisk-integration',
    'default_memory_mb' => 32_768, # 32GB RAM for databases
    'default_cpu_count' => 8,

    'node_selector' => {
      'memory-optimized' => 'true'
    },

    'env' => {
      'RAILS_ENV' => 'test',
      'DATABASE_CLEANER_ALLOW_PRODUCTION' => 'true',
      'ELASTICSEARCH_URL' => 'http://elasticsearch:9200'
    }
  }
)

# Spot instance workers for cost savings
Project.create!(
  name: 'Spot Instance Project',
  framework: 'Cypress',
  worker_provider: 'kubernetes',
  worker_concurrency: 20,
  provider_config: {
    'namespace' => 'brisk-spot',
    'default_memory_mb' => 4096,
    'default_cpu_count' => 2,

    # Target spot instances
    'node_selector' => {
      'karpenter.sh/capacity-type' => 'spot' # For Karpenter
    },

    # Tolerate spot instance evictions
    'tolerations' => [
      {
        'key' => 'karpenter.sh/capacity-type',
        'operator' => 'Equal',
        'value' => 'spot',
        'effect' => 'NoSchedule'
      }
    ]
  }
)

# Development/staging environment
Project.create!(
  name: 'Development Tests',
  framework: 'Jest',
  worker_provider: 'kubernetes',
  worker_concurrency: 2,
  provider_config: {
    'namespace' => 'brisk-dev',
    'default_memory_mb' => 2048, # Smaller resources for dev
    'default_cpu_count' => 1,

    'env' => {
      'NODE_ENV' => 'development',
      'API_URL' => 'http://api-dev.internal:3000'
    }
  }
)

# Update existing project to use Kubernetes
existing_project = Project.find_by(name: 'My Project')
existing_project.update!(
  worker_provider: 'kubernetes',
  provider_config: {
    'namespace' => 'brisk-workers',
    'default_memory_mb' => 4096,
    'default_cpu_count' => 2
  }
)

puts "Created #{Project.where(worker_provider: 'kubernetes').count} Kubernetes projects"
