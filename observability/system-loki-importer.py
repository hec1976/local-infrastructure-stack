#!/usr/bin/env python3
import json
import os
import subprocess
import time
import urllib.request
import re
from pathlib import Path

LOKI_URL = os.environ.get('TEKO_LOKI_PUSH_URL', 'http://127.0.0.1:3100/loki/api/v1/push')
STATE = Path(os.environ.get('TEKO_SYSTEM_LOKI_STATE_FILE', '/var/lib/teko-system-loki-importer/state.json'))
POLL = max(1, int(os.environ.get('TEKO_SYSTEM_LOKI_POLL_SECONDS', '2')))
MAX_EVENTS = max(10, min(5000, int(os.environ.get('TEKO_SYSTEM_LOKI_BATCH', '1000'))))
MONIT_METRICS_URL = os.environ.get('MONIT_METRICS_URL', os.environ.get('TEKO_MONIT_METRICS_URL', 'http://127.0.0.1:9108/metrics'))
MONIT_METRICS_INTERVAL = max(10, int(os.environ.get('MONIT_METRICS_INTERVAL', os.environ.get('TEKO_MONIT_METRICS_INTERVAL', '15'))))

# Only stable, useful Monit measurements are mirrored into Loki. The generic
# monit_value metric is intentionally excluded to avoid a huge number of
# low-value streams.
MONIT_METRICS = {
    'monit_up', 'monit_scrape_duration_seconds', 'monit_services_total',
    'monit_service_status', 'monit_service_monitor',
    'monit_process_cpu_percent', 'monit_process_memory_percent',
    'monit_process_memory_bytes', 'monit_process_uptime_seconds',
    'monit_system_load1', 'monit_system_load5', 'monit_system_load15',
    'monit_system_cpu_user_percent', 'monit_system_cpu_system_percent',
    'monit_system_cpu_wait_percent', 'monit_system_memory_percent',
    'monit_system_memory_bytes', 'monit_system_swap_percent',
    'monit_filesystem_space_percent', 'monit_filesystem_space_bytes',
    'monit_filesystem_total_bytes', 'monit_filesystem_inode_percent',
    'monit_host_icmp_response_seconds', 'monit_host_port_response_seconds',
    'monit_program_exit_status', 'monit_network_link_state',
    'monit_network_rx_bytes_total', 'monit_network_tx_bytes_total',
}


def load_state():
    try:
        data = json.loads(STATE.read_text(encoding='utf-8'))
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def save_state(state):
    STATE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE.with_suffix('.tmp')
    tmp.write_text(json.dumps(state) + '\n', encoding='utf-8')
    os.chmod(tmp, 0o600)
    os.replace(tmp, STATE)


def current_cursor():
    p = subprocess.run(
        ['journalctl', '-n', '0', '--show-cursor', '--no-pager'],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, check=True,
    )
    for line in reversed(p.stdout.splitlines()):
        if line.startswith('-- cursor: '):
            return line[len('-- cursor: '):].strip()
    return ''


def read_after(cursor):
    cmd = ['journalctl', '--no-pager', '-o', 'json', '--show-cursor']
    if cursor:
        cmd += ['--after-cursor', cursor]
    else:
        cmd += ['-n', '0']
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, check=True)
    events = []
    new_cursor = cursor
    for line in p.stdout.splitlines():
        if line.startswith('-- cursor: '):
            new_cursor = line[len('-- cursor: '):].strip()
            continue
        if not line.startswith('{'):
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        events.append(ev)
        if len(events) >= MAX_EVENTS:
            break
    if len(events) >= MAX_EVENTS:
        last = events[-1].get('__CURSOR')
        if last:
            new_cursor = str(last)
    return events, new_cursor


def classify(ev):
    ident = str(ev.get('SYSLOG_IDENTIFIER') or '')
    unit = str(ev.get('_SYSTEMD_UNIT') or '')
    comm = str(ev.get('_COMM') or '')
    exe = str(ev.get('_EXE') or '')
    low_ident = ident.lower()
    low_unit = unit.lower()
    low_comm = comm.lower()
    low_exe = exe.lower()

    if low_ident == 'postfix' or low_ident.startswith('postfix/') or low_ident.startswith('postfix-') \
       or low_unit == 'postfix.service' or '/postfix/' in low_exe or low_comm.startswith('postfix'):
        component = ident or comm or unit or 'postfix'
        return 'postfix', component

    if low_ident == 'monit' or low_ident.startswith('monit[') or low_unit == 'monit.service' \
       or low_comm == 'monit' or low_exe.endswith('/monit'):
        component = ident or comm or unit or 'monit'
        return 'monit', component

    return None, None


def postfix_metadata(message, component):
    low = message.lower()
    event = 'other'
    status = ''
    if 'status=sent' in low:
        event, status = 'delivery', 'sent'
    elif 'status=deferred' in low:
        event, status = 'delivery', 'deferred'
    elif 'status=bounced' in low:
        event, status = 'delivery', 'bounced'
    elif 'reject:' in low or 'reject_warning:' in low:
        event = 'reject'
    elif 'connect from ' in low:
        event = 'connect'
    elif 'disconnect from ' in low:
        event = 'disconnect'
    elif 'client=' in low:
        event = 'receive'
    elif 'removed' in low:
        event = 'queue_removed'
    elif 'warning:' in low:
        event = 'warning'
    elif 'fatal:' in low or 'panic:' in low:
        event = 'fatal'

    qid = ''
    m = re.match(r'^([A-Za-z0-9]{5,20}):\s', message)
    if m:
        qid = m.group(1)
    return event, status, qid


def monit_metadata(message):
    low = message.lower()
    if any(x in low for x in ('failed', 'does not exist', 'connection failed', 'timeout', 'error',
                              'not running', 'resource limit matched', 'permission denied')):
        state = 'problem'
    elif any(x in low for x in ('succeeded', 'connection succeeded', 'recovered', 'restarted',
                                'started', 'is running after previous error', 'accessible again')):
        state = 'recovery'
    else:
        state = 'event'

    if any(x in low for x in ('filesystem', 'space usage', 'inode')):
        event_type = 'filesystem'
    elif any(x in low for x in ('connection', 'port ', 'icmp', 'ping')):
        event_type = 'connection'
    elif any(x in low for x in ('program', 'exit status')):
        event_type = 'program'
    elif any(x in low for x in ('process', 'pid ', 'pid=')):
        event_type = 'process'
    elif any(x in low for x in ('cpu', 'memory', 'loadavg', 'load average', 'resource limit')):
        event_type = 'resource'
    elif any(x in low for x in ('checksum', 'md5', 'sha1')):
        event_type = 'checksum'
    elif any(x in low for x in ('timestamp', 'changed timestamp')):
        event_type = 'timestamp'
    elif any(x in low for x in ('permission', 'uid ', 'gid ')):
        event_type = 'permission'
    elif any(x in low for x in ('timeout', 'timed out')):
        event_type = 'timeout'
    elif any(x in low for x in ('started', 'stopped', 'restarted', 'start ', 'stop ')):
        event_type = 'lifecycle'
    else:
        event_type = 'service'

    obj = ''
    m = re.match(r"^'([^']+)'", message.strip())
    if m:
        obj = m.group(1)[:128]
    return state, event_type, obj


def timestamp_ns(ev):
    raw = ev.get('__REALTIME_TIMESTAMP')
    try:
        return str(int(raw) * 1000)
    except Exception:
        return str(int(time.time() * 1_000_000_000))


def post_streams(streams):
    if not streams:
        return
    body = json.dumps({'streams': streams}, ensure_ascii=False).encode('utf-8')
    req = urllib.request.Request(LOKI_URL, data=body, headers={'Content-Type': 'application/json'}, method='POST')
    with urllib.request.urlopen(req, timeout=10) as r:
        if r.status not in (200, 204):
            raise RuntimeError('Loki HTTP %s' % r.status)


def push(grouped):
    streams = []
    for (job, host), values in grouped.items():
        # One logical Loki stream per service/host. Postfix is deliberately NOT
        # split into smtpd/qmgr/smtp/event/status streams. Those values remain
        # JSON fields and are available only for drilldown/query-time parsing.
        labels = {'job': job, 'service': job}
        if host:
            labels['host'] = host[:128]
        labels['kind'] = 'log'
        streams.append({'stream': labels, 'values': values})
    post_streams(streams)


def process(events):
    grouped = {}
    count = {'postfix': 0, 'monit': 0}
    for ev in events:
        job, component = classify(ev)
        if not job:
            continue
        priority = str(ev.get('PRIORITY') or '')
        message = str(ev.get('MESSAGE') or '')
        hostname = str(ev.get('_HOSTNAME') or '')
        pid = str(ev.get('_PID') or ev.get('SYSLOG_PID') or '')
        identifier = str(ev.get('SYSLOG_IDENTIFIER') or '')
        unit = str(ev.get('_SYSTEMD_UNIT') or '')

        status = ''
        queue_id = ''
        if job == 'postfix':
            event, status, queue_id = postfix_metadata(message, component or '')
        else:
            event, event_type, monit_object = monit_metadata(message)

        if job != 'monit':
            event_type = ''
            monit_object = ''

        line = json.dumps({
            'message': message,
            'host': hostname,
            'pid': pid,
            'identifier': identifier,
            'unit': unit,
            'component': component or job,
            'event': event,
            'event_type': event_type,
            'monit_object': monit_object,
            'status': status,
            'priority': priority,
            'queue_id': queue_id,
        }, ensure_ascii=False, separators=(',', ':'))
        key = (job, hostname)
        grouped.setdefault(key, []).append([timestamp_ns(ev), line])
        count[job] += 1
    push(grouped)
    return count


def _unescape_label(value):
    return value.replace('\\n', '\n').replace('\\"', '"').replace('\\\\', '\\')


def parse_prometheus_line(line):
    line = line.strip()
    if not line or line.startswith('#'):
        return None
    m = re.match(r'^([A-Za-z_:][A-Za-z0-9_:]*)(?:\{(.*)\})?\s+([^\s]+)(?:\s+\d+)?$', line)
    if not m:
        return None
    name, raw_labels, raw_value = m.groups()
    if name not in MONIT_METRICS:
        return None
    try:
        value = float(raw_value)
    except Exception:
        return None
    labels = {}
    if raw_labels:
        for lm in re.finditer(r'([A-Za-z_][A-Za-z0-9_]*)="((?:\\.|[^"\\])*)"', raw_labels):
            labels[lm.group(1)] = _unescape_label(lm.group(2))
    return name, labels, value


def fetch_monit_metrics():
    req = urllib.request.Request(MONIT_METRICS_URL, headers={'User-Agent': 'TEKO-Loki-Importer/2.8.8'})
    with urllib.request.urlopen(req, timeout=5) as r:
        raw = r.read().decode('utf-8', errors='replace')
    samples = []
    for line in raw.splitlines():
        parsed = parse_prometheus_line(line)
        if parsed:
            samples.append(parsed)
    return samples


def push_monit_metrics(samples):
    # Fixed metric names plus Monit object/type make the stream set bounded by
    # the actual Monit configuration, unlike Postfix queue/event labels.
    grouped = {}
    now = int(time.time() * 1_000_000_000)
    for idx, (metric, src_labels, value) in enumerate(samples):
        obj = str(src_labels.get('service') or '')[:128]
        typ = str(src_labels.get('type') or '')[:64]
        host = str(src_labels.get('host') or '')[:128]
        stream = {
            'job': 'monit', 'service': 'monit', 'kind': 'metric', 'metric': metric,
        }
        if obj:
            stream['monit_object'] = obj
        if typ:
            stream['monit_type'] = typ
        if host:
            stream['host'] = host
        extra = dict(src_labels)
        extra.pop('service', None)
        extra.pop('type', None)
        extra.pop('host', None)
        line = json.dumps({
            'metric': metric,
            'value': value,
            'monit_object': obj,
            'monit_type': typ,
            'labels': extra,
        }, ensure_ascii=False, separators=(',', ':'))
        key = tuple(sorted(stream.items()))
        grouped.setdefault(key, {'stream': stream, 'values': []})['values'].append([str(now + idx), line])
    post_streams(list(grouped.values()))
    return len(samples)


def main():
    state = load_state()
    cursor = str(state.get('cursor') or '')
    if not cursor:
        cursor = current_cursor()
        save_state({'cursor': cursor})
        print('starting at current journal cursor=%s' % cursor[:40], flush=True)

    next_metrics = 0.0
    metrics_error_after = 0.0
    while True:
        try:
            events, new_cursor = read_after(cursor)
            counts = process(events)
            if new_cursor and new_cursor != cursor:
                cursor = new_cursor
                save_state({'cursor': cursor})
            if counts['postfix'] or counts['monit']:
                print("imported postfix=%s monit=%s" % (counts['postfix'], counts['monit']), flush=True)
        except Exception as exc:
            print('ERROR journal: %s' % exc, flush=True)

        now = time.time()
        if now >= next_metrics:
            try:
                samples = fetch_monit_metrics()
                count = push_monit_metrics(samples)
                if count:
                    print('imported monit_metrics=%s' % count, flush=True)
                next_metrics = now + MONIT_METRICS_INTERVAL
                metrics_error_after = 0.0
            except Exception as exc:
                # Exporter is installed after observability in the master setup;
                # temporary connection errors during installation are expected.
                if now >= metrics_error_after:
                    print('WARN monit metrics: %s' % exc, flush=True)
                    metrics_error_after = now + 60.0
                next_metrics = now + min(10, MONIT_METRICS_INTERVAL)
        time.sleep(POLL)


if __name__ == '__main__':
    main()
