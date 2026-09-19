from pathlib import Path

p = Path(__file__).resolve().parents[1] / "config-manager-standalone/public/agent_enrollment.php"
s = p.read_text(encoding="utf-8")
for needle in [
    "ae-status-panel",
    "overflow-y:scroll",
    "scrollbar-gutter:stable",
    "Alle öffnen",
    "Alle schliessen",
    "<details class=\"ae-job",
    "max-height:min(42vh,26rem)",
    "renderJob(row,state.openJobs.has(String(row.id||'')))",
    "jobsEl.scrollTop=oldScroll",
]:
    assert needle in s, needle
print("agent_enrollment_scroll_layout_test: PASS")
