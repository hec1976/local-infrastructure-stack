#!/usr/bin/env python3
from pathlib import Path
import importlib.util, sys
root=Path(__file__).resolve().parents[1]
worker=root/'bin/teko-agent-enrollment-worker.py'
spec=importlib.util.spec_from_file_location('teko_enroll_worker', worker)
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
noise="""Kommando fehlgeschlagen (rc=1): ssh root@host cmd\nSTDOUT:\n[!!] Vorhandene App-Unit gesichert: /opt/service/config-agent/service/config-agent.service.pre-install.20260911\n......+......+.....++++++++++++++++++++++++++++\nERROR: config-agent.service konnte nicht gestartet werden\nSTDERR:\n"""
summary=m.summarize_error(noise)
assert 'konnte nicht gestartet werden' in summary, summary
assert 'gesichert' not in summary.lower(), summary
assert '++++' not in summary, summary
php=(root/'config-manager-standalone/public/agent_enrollment.php').read_text()
assert 'x.error_summary' in php
assert 'Technische Details anzeigen' in php
print('agent_enrollment_error_readability_test: PASS')
