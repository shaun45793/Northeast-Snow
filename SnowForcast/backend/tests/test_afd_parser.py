from __future__ import annotations

from datetime import datetime, timezone

from app.clients.nws import NWSAFDProduct
from app.services.afd_parser import build_discussion_model, parse_afd_sections


SAMPLE_BTV_AFD = """
AREA FORECAST DISCUSSION
NATIONAL WEATHER SERVICE BURLINGTON VT
345 PM EST TUE NOV 24 2026

.SYNOPSIS...
A vigorous upper trough moves across the northern Green Mountains tonight
with deep northwest upslope flow developing behind the arctic front.

.SHORT TERM...
Favorable northwest flow and dendritic growth zone saturation will bring
accumulating upslope snow to Jay Peak and Stowe above 2000 feet. Expect
4 to 8 inches along the summit spine with 15:1 snow ratios overnight.
Ridgetop wind gusts to 40 mph may cause localized lift holds on exposed peaks.

.LONG TERM...
ECMWF and GEM ensembles remain in good agreement for another clipper late week,
though GFS shows higher spread on coastal low track. Confidence is high for
cold temperatures continuing.
&&
$$
SMITH
"""


def test_afd_section_parsing_and_highlights():
    sections = parse_afd_sections(SAMPLE_BTV_AFD)
    assert "SYNOPSIS" in sections
    assert "SHORT TERM" in sections
    assert "LONG TERM" in sections
    assert "\n" not in sections["SYNOPSIS"]  # reflowed single paragraph

    product = NWSAFDProduct(
        wfo_id="BTV",
        product_id="btv-123",
        issued_at=datetime(2026, 11, 24, 20, 45, tzinfo=timezone.utc),
        raw_text=SAMPLE_BTV_AFD,
        forecaster="SMITH",
    )
    discussion = build_discussion_model(product, is_live=True)
    assert discussion.wfo_id == "BTV"
    assert discussion.forecaster == "SMITH"
    assert "stowe" in discussion.covered_mountain_ids
    assert "jay-peak" in discussion.covered_mountain_ids
    categories = {h.category for h in discussion.highlights}
    assert "Snow & Upslope" in categories
    assert "Wind & Hold Risk" in categories
    assert "Confidence & Models" in categories
