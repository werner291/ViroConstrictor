"""Regression tests for the per-scheduler ExecutorSettings wiring in
``ViroConstrictor.workflow_executor``.

Background
----------
``snakemake-executor-plugin-slurm`` 2.0.0 (the version pinned in
``env.yml``) reads ``self.workflow.executor_settings.logdir`` inside its
``Executor.__post_init__`` (see plugin ``__init__.py`` ll. 209-217).
``workflow.executor_settings`` is whatever the caller passed to
``dag_api.execute_workflow(executor_settings=...)``; if no instance is
passed, snakemake leaves it as ``None`` and the plugin AttributeErrors
before the first ``sbatch`` call.

The local executor and the dryrun executor don't ship an
``ExecutorSettings`` dataclass and accept ``None``. The helper
``_executor_settings_for`` returns the right instance per scheduler,
``None`` for in-process executors, plugin-specific settings for remote
ones.
"""
from unittest import mock

import pytest

from ViroConstrictor.scheduler import Scheduler


class TestExecutorSettingsFor:
    """Behavioural tests for the per-scheduler ExecutorSettings selector.

    The helper itself is imported lazily inside each test so the
    integration tests below can still be collected if the helper
    regresses or is renamed."""

    @pytest.mark.parametrize(
        "scheduler",
        [Scheduler.LOCAL, Scheduler.DRYRUN, Scheduler.LSF],
    )
    def test_returns_none_for_in_process_or_unhandled(self, scheduler):
        """Local + dryrun execute in-process and need no plugin settings;
        LSF's plugin (0.2.6, env.yml-pinned) reads no executor_settings
        attributes in ``__post_init__`` so passing ``None`` is harmless.
        Future versions may grow that requirement, in which case this
        test is the place to extend the helper."""
        from ViroConstrictor.workflow_executor import _executor_settings_for

        assert _executor_settings_for(scheduler) is None

    def test_returns_slurm_executor_settings_with_logdir_attr(self):
        """The slurm plugin's ``__post_init__`` reads ``.logdir`` and
        ``.partition_config`` on whatever instance the API call passes.
        ``None`` AttributeErrors before the first sbatch; this test pins
        that the helper returns an object with those attributes so the
        plugin moves past initialisation."""
        slurm_module = pytest.importorskip("snakemake_executor_plugin_slurm")
        from ViroConstrictor.workflow_executor import _executor_settings_for

        settings = _executor_settings_for(Scheduler.SLURM)
        assert settings is not None
        assert isinstance(settings, slurm_module.ExecutorSettings)
        # Attributes that the plugin's __post_init__ touches.
        assert hasattr(settings, "logdir")
        assert hasattr(settings, "partition_config")


class TestWorkflowExecutorPassesSettings:
    """Integration check at the dispatcher level: when a SLURM scheduler
    is selected, ``WorkflowExecutor.__init__`` must forward a non-``None``
    ``executor_settings`` to ``dag_api.execute_workflow``. Pre-fix the
    kwarg was omitted entirely (defaulting to ``None`` inside snakemake),
    which is what produced the runtime AttributeError on real clusters."""

    def _run_executor(self, scheduler):
        """Build a ``WorkflowExecutor`` against fully-mocked snakemake API
        objects so we can assert what got forwarded into
        ``execute_workflow`` without booting an actual workflow."""
        from ViroConstrictor.workflow_executor import WorkflowExecutor

        fake_workflow_config = mock.MagicMock()
        fake_parsed_input = mock.MagicMock()

        with mock.patch("ViroConstrictor.workflow_executor.SnakemakeApi") as api_cls:
            api_ctx = api_cls.return_value.__enter__.return_value
            dag_api = api_ctx.workflow.return_value.dag.return_value

            WorkflowExecutor(
                parsed_input=fake_parsed_input,
                workflow_config=fake_workflow_config,
                scheduler=scheduler,
            )

            return dag_api.execute_workflow.call_args

    def test_slurm_forwards_non_none_executor_settings(self):
        pytest.importorskip("snakemake_executor_plugin_slurm")
        call = self._run_executor(Scheduler.SLURM)
        # snakemake's API takes executor_settings as a kwarg; assert it
        # is present and not None.
        assert call is not None, "execute_workflow was never called"
        assert "executor_settings" in call.kwargs
        assert call.kwargs["executor_settings"] is not None

    def test_local_forwards_none_executor_settings(self):
        call = self._run_executor(Scheduler.LOCAL)
        assert call is not None
        # For the local executor the kwarg may be present with value
        # ``None`` or absent; either is correct — what matters is that
        # the plugin doesn't get a stale settings object.
        assert call.kwargs.get("executor_settings") is None
