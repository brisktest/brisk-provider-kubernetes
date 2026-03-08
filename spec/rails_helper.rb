# frozen_string_literal: true

ENV['RAILS_ENV'] ||= 'test'

require 'spec_helper'

# Set up a minimal Rails environment for testing
require 'active_record'
require 'active_support/all'
require 'logger'

# Set up a minimal Rails stub
unless defined?(Rails)
  module Rails
    def self.logger
      @logger ||= Logger.new($stdout).tap do |log|
        log.level = Logger::ERROR
      end
    end

    def self.root
      Pathname.new(File.expand_path('../..', __dir__))
    end

    def self.env
      ActiveSupport::StringInquirer.new(ENV['RAILS_ENV'] || 'test')
    end

    def self.application
      self
    end

    def self.config
      @config ||= Struct.new(:eager_load).new(false)
    end
  end
end

# Configure in-memory SQLite database
ActiveRecord::Base.establish_connection(
  adapter: 'sqlite3',
  database: ':memory:'
)

require 'factory_bot_rails'

# Define Providers namespace and base classes expected by the gem
module Providers
  class ProviderError < StandardError; end
  class ConfigurationError < StandardError; end
  class UnsupportedOperationError < StandardError; end

  class BaseProvider
    attr_reader :project

    def initialize(project)
      @project = project
    end

    # These methods should be implemented by subclasses
    def get_workers_for_project(jobrun)
      raise NotImplementedError
    end

    def create_worker(machine_config)
      raise NotImplementedError
    end

    def start_worker(worker)
      raise NotImplementedError
    end

    def stop_worker(worker)
      raise NotImplementedError
    end

    def suspend_worker(worker)
      raise NotImplementedError
    end

    def destroy_worker(worker)
      raise NotImplementedError
    end

    def reconcile_workers
      raise NotImplementedError
    end

    def supports?(_feature)
      false
    end

    def after_worker_allocated(workers)
      # Hook for post-allocation logic
    end

    def after_worker_freed(worker)
      # Hook for post-free logic
    end

    def should_track_health?(_worker)
      true
    end

    def register_worker_metadata(_worker, _params)
      {}
    end

    def manages_machine?(_machine)
      false
    end
  end
end

# Load the provider library
require 'brisk-provider-kubernetes'
require 'brisk/providers/kubernetes/provider'

# Define minimal ActiveRecord models for testing
# Stub ProjectService for provider delegation
class ProjectService
  def self.get_workers_for_project(jobrun)
    []
  end
end

class Project < ActiveRecord::Base
  serialize :provider_config, coder: JSON
  has_many :machines
  has_many :workers

  # Mock the image method that returns an object with url
  def image
    return nil if attributes['image'].nil?

    @image ||= Struct.new(:url).new(attributes['image'])
  end

  def worker_concurrency
    10 # Default for tests
  end

  def balance_workers
    # no-op in tests
  end
end

class Worker < ActiveRecord::Base
  belongs_to :project
  belongs_to :machine, optional: true

  def de_register!
    update!(state: 'finished')
  end

  def finished?
    state == 'finished'
  end
end

class Machine < ActiveRecord::Base
  belongs_to :project
end

# Create database schema
ActiveRecord::Schema.define do
  create_table :projects, force: true do |t|
    t.string :worker_provider
    t.text :provider_config
    t.string :image
    t.timestamps
  end

  create_table :workers, force: true do |t|
    t.integer :project_id
    t.integer :machine_id
    t.string :state, default: 'active'
    t.timestamps
  end

  create_table :machines, force: true do |t|
    t.integer :project_id
    t.string :provider
    t.string :uid
    t.string :state
    t.datetime :finished_at
    t.timestamps
  end
end

# Set up FactoryBot
RSpec.configure do |config|
  config.include FactoryBot::Syntax::Methods

  config.before(:suite) do
    FactoryBot.find_definitions
  end

  config.around do |example|
    ActiveRecord::Base.transaction do
      example.run
      raise ActiveRecord::Rollback
    end
  end
end
