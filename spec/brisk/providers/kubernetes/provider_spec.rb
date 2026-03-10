# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Brisk::Providers::Kubernetes::Provider do
  let(:project) do
    create(:project,
           worker_provider: 'kubernetes',
           provider_config: {
             'namespace' => 'brisk-test'
           })
  end
  let(:provider) { described_class.new(project) }
  let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil, debug: nil) }

  before do
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

  describe '#get_workers_for_project' do
    it 'delegates to ProjectService' do
      jobrun = double('Jobrun')
      allow(ProjectService).to receive(:get_workers_for_project).with(jobrun).and_return([])

      result = provider.get_workers_for_project(jobrun)

      expect(result).to eq([])
      expect(ProjectService).to have_received(:get_workers_for_project).with(jobrun)
    end
  end

  describe '#create_worker' do
    it 'raises UnsupportedOperationError' do
      expect { provider.create_worker({}) }.to raise_error(
        Providers::UnsupportedOperationError,
        /managed by the cluster Deployment/
      )
    end
  end

  describe '#start_worker' do
    it 'logs that workers are managed by Deployment' do
      worker = create(:worker, project: project)
      expect(logger).to receive(:info).with(/Cannot start worker.*managed by Deployment/)

      provider.start_worker(worker)
    end
  end

  describe '#stop_worker' do
    it 'logs that workers are managed by Deployment' do
      worker = create(:worker, project: project)
      expect(logger).to receive(:info).with(/Cannot stop worker.*managed by Deployment/)

      provider.stop_worker(worker)
    end
  end

  describe '#suspend_worker' do
    it 'logs that suspend is not supported' do
      worker = create(:worker, project: project)
      expect(logger).to receive(:info).with(/Suspend not supported/)

      provider.suspend_worker(worker)
    end
  end

  describe '#destroy_worker' do
    it 'de-registers the worker' do
      worker = create(:worker, project: project, state: 'active')

      provider.destroy_worker(worker)

      expect(worker.reload.state).to eq('finished')
    end

    it 'skips de-register if already finished' do
      worker = create(:worker, project: project, state: 'finished')

      expect { provider.destroy_worker(worker) }.not_to raise_error
    end

    it 'logs the de-registration' do
      worker = create(:worker, project: project)
      expect(logger).to receive(:info).with(/de-registered/)

      provider.destroy_worker(worker)
    end
  end

  describe '#reconcile_workers' do
    let(:kube_client) { instance_double(Brisk::Providers::Kubernetes::KubeClient) }

    context 'when not in a Kubernetes cluster' do
      before do
        allow(Brisk::Providers::Kubernetes::KubeClient).to receive(:in_cluster?).and_return(false)
      end

      it 'skips reconciliation' do
        expect(logger).to receive(:info).with(/Not running in a Kubernetes cluster/)

        provider.reconcile_workers
      end
    end

    context 'when K8s API is unavailable' do
      before do
        allow(Brisk::Providers::Kubernetes::KubeClient).to receive(:in_cluster?).and_return(true)
        allow(Brisk::Providers::Kubernetes::KubeClient).to receive(:new).and_raise(
          Brisk::Providers::Kubernetes::KubeApiError, 'connection refused'
        )
      end

      it 'logs a warning and returns gracefully' do
        expect(logger).to receive(:warn).with(/K8s API unavailable/)

        expect { provider.reconcile_workers }.not_to raise_error
      end
    end

    context 'when in a Kubernetes cluster' do
      let!(:running_machine) { create(:machine, provider: 'kubernetes', uid: 'worker-pod-abc') }
      let!(:ghost_machine) { create(:machine, provider: 'kubernetes', uid: 'worker-pod-gone') }
      let!(:stale_machine) { create(:machine, provider: 'kubernetes', uid: 'worker-pod-old') }

      let!(:running_worker) do
        create(:worker, project: project, machine: running_machine, state: 'assigned',
                        freed_at: nil, reserved_at: 2.minutes.ago, supervisor_id: 1)
      end

      let!(:ghost_worker) do
        create(:worker, project: project, machine: ghost_machine, state: 'assigned',
                        freed_at: nil, reserved_at: 10.minutes.ago, supervisor_id: 1)
      end

      let!(:stale_free_worker) do
        create(:worker, project: project, machine: stale_machine, state: 'assigned',
                        freed_at: 15.minutes.ago, reserved_at: nil)
      end

      before do
        allow(Brisk::Providers::Kubernetes::KubeClient).to receive_messages(in_cluster?: true, new: kube_client)
        pods_response = [
          { name: 'worker-pod-abc', status: 'Running', ip: '10.0.0.1' },
          { name: 'worker-pod-new', status: 'Running', ip: '10.0.0.2' }
        ]
        allow(kube_client).to receive(:list_pods).and_return(pods_response)
      end

      it 'frees ghost busy workers whose pods are gone' do
        provider.reconcile_workers

        ghost_worker.reload
        expect(ghost_worker.freed_at).not_to be_nil
        expect(ghost_worker.supervisor_id).to be_nil
      end

      it 'de-registers stale free workers whose pods are gone' do
        provider.reconcile_workers

        stale_free_worker.reload
        expect(stale_free_worker.state).to eq('finished')
      end

      it 'does not touch workers whose pods are still running' do
        provider.reconcile_workers

        running_worker.reload
        expect(running_worker.state).to eq('assigned')
        expect(running_worker.freed_at).to be_nil
      end

      it 'does not touch recently assigned ghost workers (within 5 min threshold)' do
        recent_machine = create(:machine, provider: 'kubernetes', uid: 'worker-pod-recent-gone')
        recent_ghost = create(:worker, project: project, machine: recent_machine, state: 'assigned',
                                       freed_at: nil, reserved_at: 2.minutes.ago, supervisor_id: 1)

        provider.reconcile_workers

        recent_ghost.reload
        expect(recent_ghost.state).to eq('assigned')
        expect(recent_ghost.freed_at).to be_nil
      end

      it 'logs a summary of actions taken' do
        expect(logger).to receive(:info).with(/Reconciliation complete.*freed 1 ghost.*de-registered 1 stale/)

        provider.reconcile_workers
      end

      it 'uses the namespace from provider_config' do
        allow(kube_client).to receive(:list_pods).and_return([])

        provider.reconcile_workers

        expect(kube_client).to have_received(:list_pods).with(
          namespace: 'brisk-test',
          label_selector: 'app=worker'
        )
      end

      it 'continues reconciliation even if one worker fails' do
        allow_any_instance_of(Worker).to receive(:free_from_super).and_raise(StandardError, 'lock timeout') # rubocop:disable RSpec/AnyInstance
        expect(logger).to receive(:error).with(/Error reconciling worker/)

        expect { provider.reconcile_workers }.not_to raise_error
      end
    end
  end

  describe '#supports?' do
    it 'supports self_registration' do
      expect(provider.supports?(:self_registration)).to be true
    end

    it 'does not support suspend' do
      expect(provider.supports?(:suspend)).to be false
    end

    it 'does not support dynamic_creation' do
      expect(provider.supports?(:dynamic_creation)).to be false
    end

    it 'returns false for unknown features' do
      expect(provider.supports?(:unknown)).to be false
    end
  end

  describe '#should_track_health?' do
    it 'returns false because Kubernetes manages health' do
      worker = create(:worker, project: project)
      expect(provider.should_track_health?(worker)).to be false
    end
  end

  describe '#register_worker_metadata' do
    it 'returns metadata with far-future last_checked_at' do
      worker = create(:worker, project: project)
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

    it 'returns false for machines with blank provider' do
      machine = create(:machine, provider: '')
      expect(provider.manages_machine?(machine)).to be false
    end

    it 'returns false for other provider machines' do
      machine = create(:machine, provider: 'flyio')
      expect(provider.manages_machine?(machine)).to be false
    end
  end

  describe '#after_worker_allocated' do
    it 'logs the allocation' do
      workers = [create(:worker, project: project)]
      expect(logger).to receive(:debug).with(/1 workers allocated/)

      provider.after_worker_allocated(workers)
    end

    it 'does not call balance_workers (pod count managed by Deployment)' do
      workers = [create(:worker, project: project)]
      expect(project).not_to receive(:balance_workers)

      provider.after_worker_allocated(workers)
    end
  end

  describe '#after_worker_freed' do
    it 'logs the freed worker' do
      worker = create(:worker, project: project)
      expect(logger).to receive(:debug).with(/freed/)

      provider.after_worker_freed(worker)
    end
  end

  describe '#claim_supervisor' do
    it 'logs that supervisor pod is always running' do
      supervisor = double('Supervisor', id: 1)
      expect(logger).to receive(:debug).with(/claimed.*always running/)

      provider.claim_supervisor(supervisor)
    end
  end

  describe '#release_supervisor' do
    it 'clears in_use on the supervisor' do
      supervisor = double('Supervisor', id: 1, in_use: Time.current)
      expect(supervisor).to receive(:in_use=).with(nil)

      provider.release_supervisor(supervisor)
    end
  end

  describe '#after_supervisor_released' do
    it 'frees workers still assigned to the supervisor' do
      worker = double('Worker', id: 1)
      workers_relation = double('WorkersRelation')
      supervisor = double('Supervisor', id: 1, workers: workers_relation)
      allow(workers_relation).to receive(:where).with(freed_at: nil).and_return([worker])
      expect(worker).to receive(:free_from_super)

      provider.after_supervisor_released(supervisor)
    end

    it 'handles errors when freeing workers' do
      worker = double('Worker', id: 1)
      workers_relation = double('WorkersRelation')
      supervisor = double('Supervisor', id: 1, workers: workers_relation)
      allow(workers_relation).to receive(:where).with(freed_at: nil).and_return([worker])
      allow(worker).to receive(:free_from_super).and_raise(StandardError, 'test error')
      expect(logger).to receive(:error).with(/Failed to free worker/)

      expect { provider.after_supervisor_released(supervisor) }.not_to raise_error
    end

    it 'does nothing when no busy workers remain' do
      workers_relation = double('WorkersRelation')
      supervisor = double('Supervisor', id: 1, workers: workers_relation)
      allow(workers_relation).to receive(:where).with(freed_at: nil).and_return([])

      expect { provider.after_supervisor_released(supervisor) }.not_to raise_error
    end
  end

  describe '#cleanup_supervisor' do
    it 'logs that pod lifecycle is managed by Kubernetes' do
      supervisor = double('Supervisor', id: 1)
      expect(logger).to receive(:debug).with(/managed by Kubernetes/)

      provider.cleanup_supervisor(supervisor)
    end
  end
end
