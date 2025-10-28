# frozen_string_literal: true

# Only require the version file, not the entire library
# (to avoid loading Rails dependency during gemspec evaluation)
require_relative 'lib/brisk/providers/kubernetes/version'

Gem::Specification.new do |spec|
  spec.name        = 'brisk-provider-kubernetes'
  spec.version     = Brisk::Providers::Kubernetes::VERSION
  spec.authors     = ['Brisk Team']
  spec.email       = ['support@brisk.dev']
  spec.summary     = 'Kubernetes provider for Brisk CI'
  spec.description = 'Manage Brisk workers as Kubernetes pods in your cluster'
  spec.homepage    = 'https://github.com/brisktest/brisk-provider-kubernetes'
  spec.license     = 'MIT'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/brisktest/brisk-provider-kubernetes'
  spec.metadata['changelog_uri'] = 'https://github.com/brisktest/brisk-provider-kubernetes/blob/main/CHANGELOG.md'
  spec.metadata['documentation_uri'] = 'https://docs.brisk.dev/providers/kubernetes'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['{app,config,db,lib}/**/*', 'MIT-LICENSE', 'Rakefile', 'README.md']
  spec.require_paths = ['lib']

  # Runtime dependencies
  spec.add_dependency 'k8s-ruby', '~> 0.10' # Kubernetes client library
  spec.add_dependency 'rails', '>= 7.0'

  # Development dependencies
  spec.add_development_dependency 'factory_bot_rails', '~> 6.0'
  spec.add_development_dependency 'rspec-rails', '~> 6.0'
  spec.add_development_dependency 'sqlite3', '~> 2.1'
  spec.add_development_dependency 'webmock', '~> 3.0'

  spec.required_ruby_version = '>= 3.2.0'
end
