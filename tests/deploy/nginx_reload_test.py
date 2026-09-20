#!/usr/bin/env python3
"""Readiness must wait for all original nginx workers, not new worker startup."""
import unittest
import subprocess
import tempfile
from pathlib import Path
from unittest.mock import Mock, patch

from nginx_rehearsal import wait_for_retired_workers, rehearsal_session


class ReloadReadiness(unittest.TestCase):
    def test_new_worker_start_and_partial_retirement_are_not_ready(self):
        log = Mock()
        new = 'start worker process 303\n'
        log.read_text.side_effect = [new,
            new + 'worker process 101 exited with code 0\n',
            new + 'worker process 101 exited with code 0\nworker process 202 exited with code 0\n']
        with patch('nginx_rehearsal.time.sleep') as pause:
            wait_for_retired_workers(Mock(poll=lambda: None), log, {101, 202})
        self.assertEqual(log.read_text.call_count, 3)
        self.assertEqual(pause.call_count, 2)

    def test_unsuccessful_exit_is_not_ready(self):
        log = Mock(read_text=lambda **kwargs: 'worker process 101 exited with code 1\n')
        with self.assertRaisesRegex(AssertionError, 'unsuccessfully'):
            wait_for_retired_workers(Mock(poll=lambda: None), log, {101})

    def test_live_old_worker_times_out_even_if_new_worker_started(self):
        log = Mock(read_text=lambda **kwargs: 'start worker process 303\n')
        with patch('nginx_rehearsal.time.monotonic', side_effect=[0, 0, 11]), patch('nginx_rehearsal.time.sleep'):
            with self.assertRaisesRegex(AssertionError, 'did not retire.*101'):
                wait_for_retired_workers(Mock(poll=lambda: None), log, {101})

    def test_no_worker_evidence_and_dead_master_fail(self):
        with self.assertRaisesRegex(AssertionError, 'no original worker'):
            wait_for_retired_workers(Mock(poll=lambda: None), Mock(), set())
        with self.assertRaisesRegex(AssertionError, 'master exited'):
            wait_for_retired_workers(Mock(poll=lambda: 1), Mock(), {101})


class SessionCleanup(unittest.TestCase):
    def test_browser_setup_failure_stops_host_and_closes_log(self):
        host = Mock()
        browser = Mock(new_context=Mock(side_effect=RuntimeError('browser unavailable')))
        with tempfile.TemporaryDirectory() as temp, patch('nginx_rehearsal.subprocess.Popen', return_value=host) as spawn:
            with self.assertRaisesRegex(RuntimeError, 'browser unavailable'):
                with rehearsal_session(browser, ['nginx'], Path(temp) / 'log'):
                    self.fail('session should not start')
            host.terminate.assert_called_once()
            host.wait.assert_called_once_with(timeout=10)
            self.assertTrue(spawn.call_args.kwargs['stdout'].closed)

    def test_body_or_context_close_failure_still_stops_host(self):
        for failure in ['body', 'close']:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temp:
                host, context = Mock(), Mock()
                if failure == 'close':
                    context.close.side_effect = RuntimeError('close')
                with patch('nginx_rehearsal.subprocess.Popen', return_value=host):
                    with self.assertRaisesRegex(RuntimeError, failure):
                        with rehearsal_session(Mock(new_context=lambda: context), ['nginx'], Path(temp) / 'log'):
                            if failure == 'body':
                                raise RuntimeError('body')
                context.close.assert_called_once()
                host.terminate.assert_called_once()
                host.wait.assert_called_once_with(timeout=10)

    def test_stuck_host_is_killed_and_reaped(self):
        host = Mock(wait=Mock(side_effect=[subprocess.TimeoutExpired('nginx', 10), 0]))
        with tempfile.TemporaryDirectory() as temp, patch('nginx_rehearsal.subprocess.Popen', return_value=host):
            with rehearsal_session(Mock(), ['nginx'], Path(temp) / 'log'):
                pass
        host.kill.assert_called_once()
        self.assertEqual(host.wait.call_args_list[-1].kwargs, {'timeout': 5})

    def test_start_failure_closes_log(self):
        with tempfile.TemporaryDirectory() as temp, patch('nginx_rehearsal.subprocess.Popen', side_effect=OSError('start')) as spawn:
            with self.assertRaisesRegex(OSError, 'start'):
                with rehearsal_session(Mock(), ['nginx'], Path(temp) / 'log'):
                    self.fail('session should not start')
            self.assertTrue(spawn.call_args.kwargs['stdout'].closed)


if __name__ == '__main__':
    unittest.main()
