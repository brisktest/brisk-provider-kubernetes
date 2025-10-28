# frozen_string_literal: true

module Brisk
  module Providers
    module Kubernetes
      # Rails Engine for Kubernetes provider
      # Auto-registers provider when gem is loaded
      class Engine < ::Rails::Engine
        isolate_namespace Brisk::Providers::Kubernetes

        # Auto-register provider when Rails boots
        initializer 'brisk_provider_kubernetes.register', before: :load_config_initializers do |app|
          app.config.to_prepare do
            if defined?(::Providers::ProviderRegistry)
              ::Providers::ProviderRegistry.instance.register(
                'kubernetes',
                Brisk::Providers::Kubernetes::Provider
              )
              Rails.logger.info '✓ Kubernetes Provider registered'
            else
              Rails.logger.warn '⚠ Cannot register Kubernetes Provider - ProviderRegistry not found'
            end
          end
        end

        # Add any migrations from this gem to the main app
        initializer 'brisk_provider_kubernetes.migrations' do |app|
          unless app.root.to_s.match?(root.to_s)
            config.paths['db/migrate'].expanded.each do |expanded_path|
              app.config.paths['db/migrate'] << expanded_path
            end
          end
        end
      end
    end
  end
end
