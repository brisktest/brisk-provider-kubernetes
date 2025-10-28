# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Brisk::Providers::Kubernetes::Provider do
  let(:project) do
    create(:project,
           worker_provider: 'kubernetes',
           provider_config: {
             'namespace' => 'brisk-test',
             'env' => { 'CUSTOM_VAR' => 'value' }
           })
  end
  let(:provider) { described_class.new(project) }
  let(:k8s_client) { instance_double(K8s::Client) }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil, debug: nil) }

  before do
    allow(provider).to receive(:k8s_client).and_return(k8s_client)
    allow(Rails).to receive(:logger).and_return(logger)
  end

  describe 'interface compliance' do
    it 'inherits from BaseProvider' do
      expect(described_class.ancestors).to include(Providers::BaseProvider)
    end

    it 'implements all required methods' do
      expect(provider).to respond_to(:get_workers_for_project)
      expect(provider).to respond_to(:create_worker)
      expect(provider).to respond_to(:start_worker)
      expect(provider).to respond_to(:stop_worker)
      expect(provider).to respond_to(:suspend_worker)
      expect(provider).to respond_to(:destroy_worker)
      expect(provider).to respond_to(:reconcile_workers)
      expect(provider).to respond_to(:supports?)
      expect(provider).to respond_to(:after_worker_allocated)
      expect(provider).to respond_to(:after_worker_freed)
      expect(provider).to respond_to(:should_track_health?)
      expect(provider).to respond_to(:register_worker_metadata)
      expect(provider).to respond_to(:manages_machine?)
    end
  end

  describe '#supports?' do
    it 'supports dynamic_creation' do
      expect(provider.supports?(:dynamic_creation)).to be true
    end

    it 'does not support suspend' do
      expect(provider.supports?(:suspend)).to be false
    end

    it 'supports auto_scale' do
      expect(provider.supports?(:auto_scale)).to be true
    end

    it 'does not support spot_instances' do
      expect(provider.supports?(:spot_instances)).to be false
    end

    it 'returns false for unknown features' do
      expect(provider.supports?(:unknown)).to be false
    end
  end

  describe '#should_track_health?' do
    let(:worker) { create(:worker, project: project) }

    it 'returns false because Kubernetes manages health' do
      expect(provider.should_track_health?(worker)).to be false
    end
  end

  describe '#register_worker_metadata' do
    let(:worker) { create(:worker, project: project) }

    it 'returns metadata with disabled health tracking' do
      metadata = provider.register_worker_metadata(worker, {})

      expect(metadata).to be_a(Hash)
      expect(metadata[:last_checked_at]).to be > 1.year.from_now
    end
  end

  describe '#manages_machine?' do
    it 'returns true for kubernetes machines' do
      machine = create(:machine, provider: 'kubernetes')
      expect(provider.manages_machine?(machine)).to be true
    end

    it 'returns false for other provider machines' do
      machine = create(:machine, provider: 'flyio')
      expect(provider.manages_machine?(machine)).to be false
    end
  end

  describe '#stop_worker' do
    let(:machine) { create(:machine, provider: 'kubernetes', uid: 'test-pod-123') }
    let(:worker) { create(:worker, project: project, machine: machine) }
    let(:pods_resource) { double('K8s::Resource') }
    let(:v1_api) { double('K8s::API') }

    before do
      allow(k8s_client).to receive(:api).with('v1').and_return(v1_api)
      allow(v1_api).to receive(:resource).with('pods', namespace: 'brisk-test').and_return(pods_resource)
    end

    it 'deletes the pod' do
      expect(pods_resource).to receive(:delete).with(
        'test-pod-123',
        propagationPolicy: 'Foreground'
      )

      provider.stop_worker(worker)
    end

    it 'handles not found errors gracefully' do
      allow(pods_resource).to receive(:delete).and_raise(
        K8s::Error::NotFound.new('DELETE', '/pods/test-pod-123', 404, 'Not Found')
      )

      expect { provider.stop_worker(worker) }.not_to raise_error
    end

    it 'raises ProviderError for other API errors' do
      allow(pods_resource).to receive(:delete).and_raise(
        K8s::Error::API.new('DELETE', '/pods/test-pod-123', 500, 'Server Error')
      )

      expect { provider.stop_worker(worker) }.to raise_error(Providers::ProviderError, /Failed to stop pod/)
    end
  end

  describe '#destroy_worker' do
    let(:machine) { create(:machine, provider: 'kubernetes', uid: 'test-pod-456') }
    let(:worker) { create(:worker, project: project, machine: machine) }
    let(:pods_resource) { double('K8s::Resource') }
    let(:v1_api) { double('K8s::API') }

    before do
      allow(k8s_client).to receive(:api).with('v1').and_return(v1_api)
      allow(v1_api).to receive(:resource).with('pods', namespace: 'brisk-test').and_return(pods_resource)
    end

    it 'deletes the pod with grace period' do
      expect(pods_resource).to receive(:delete).with(
        'test-pod-456',
        propagationPolicy: 'Foreground',
        gracePeriodSeconds: 30
      )

      provider.destroy_worker(worker)
    end

    it 'updates machine state' do
      allow(pods_resource).to receive(:delete)

      expect do
        provider.destroy_worker(worker)
      end.to change { worker.machine.reload.state }.to('terminated')
    end
  end

  describe '#reconcile_workers' do
    let(:pods_resource) { double('K8s::Resource') }
    let(:v1_api) { double('K8s::API') }
    let(:pod1) { double(metadata: double(name: 'pod-1')) }
    let(:pod2) { double(metadata: double(name: 'pod-2')) }
    let(:pod3) { double(metadata: double(name: 'pod-orphaned')) }

    before do
      allow(k8s_client).to receive(:api).with('v1').and_return(v1_api)
      allow(v1_api).to receive(:resource).with('pods', namespace: 'brisk-test').and_return(pods_resource)

      # Mock existing machines
      create(:machine, provider: 'kubernetes', uid: 'pod-1', project: project)
      create(:machine, provider: 'kubernetes', uid: 'pod-2', project: project)
    end

    it 'deletes orphaned pods' do
      allow(pods_resource).to receive(:list).with(
        labelSelector: "brisk-project-id=#{project.id},brisk-role=worker"
      ).and_return([pod1, pod2, pod3])

      expect(pods_resource).to receive(:delete).with('pod-orphaned', propagationPolicy: 'Background')

      provider.reconcile_workers
    end

    it 'handles API errors gracefully' do
      allow(pods_resource).to receive(:list).and_raise(
        K8s::Error::API.new('GET', '/pods', 500, 'Error')
      )

      expect { provider.reconcile_workers }.not_to raise_error
    end
  end

  describe '#after_worker_allocated' do
    it 'logs debug message' do
      workers = [create(:worker, project: project)]

      expect(logger).to receive(:debug).with(/K8s.*1 workers allocated/)
      provider.after_worker_allocated(workers)
    end
  end

  describe '#after_worker_freed' do
    let(:worker) { create(:worker, project: project) }

    it 'logs info message' do
      expect(logger).to receive(:info).with(/K8s.*Scheduling cleanup/)
      provider.after_worker_freed(worker)
    end
  end

  describe 'private methods' do
    describe '#k8s_namespace' do
      it 'uses namespace from provider_config' do
        expect(provider.send(:k8s_namespace)).to eq('brisk-test')
      end

      it 'falls back to environment variable' do
        project.provider_config.delete('namespace')
        allow(ENV).to receive(:[]).with('K8S_NAMESPACE').and_return('env-namespace')

        expect(provider.send(:k8s_namespace)).to eq('env-namespace')
      end

      it 'falls back to default namespace' do
        project.provider_config.delete('namespace')
        allow(ENV).to receive(:[]).with('K8S_NAMESPACE').and_return(nil)

        expect(provider.send(:k8s_namespace)).to eq('brisk-workers')
      end
    end

    describe '#validate_config!' do
      it 'succeeds with valid config' do
        expect { provider.send(:validate_config!) }.not_to raise_error
      end

      it 'raises error if image is missing' do
        project.image = nil

        expect do
          provider.send(:validate_config!)
        end.to raise_error(Providers::ConfigurationError, /image not configured/)
      end
    end
  end
end
