from __future__ import annotations

import re
from datetime import datetime, timezone
from typing import Dict, List, Optional, Tuple

from app.clients.nws import NWSAFDProduct
from app.config import NORTHEAST_MOUNTAINS, WFO_OFFICES
from app.models import MeteorologistDiscussion, MeteorologistHighlight

SECTION_PATTERN = re.compile(
    r"^\.(SYNOPSIS|NEAR TERM|SHORT TERM|LONG TERM|AVIATION|MARINE|CLIMATE)\b[^.\n]*\.{0,3}",
    re.MULTILINE | re.IGNORECASE,
)

CATEGORY_KEYWORDS: List[Tuple[str, Tuple[str, ...]]] = [
    (
        "Snow & Upslope",
        (
            "snow",
            "upslope",
            "flurries",
            "squall",
            "accumulation",
            "inch",
            "dendritic",
            "slr",
            "ratio",
            "orographic",
            "green mountain",
            "white mountain",
            "adirondack",
            "lake effect",
        ),
    ),
    (
        "Temp & Freezing Level",
        (
            "freezing level",
            "snow level",
            "sleet",
            "freezing rain",
            "mixed",
            "mix",
            "warm nose",
            "850",
            "925",
            "cold air",
            "temperature",
            "elevation",
        ),
    ),
    (
        "Wind & Hold Risk",
        (
            "wind",
            "gust",
            "ridgetop",
            "wind chill",
            "blowing snow",
            "lift hold",
            "advisory",
            "gale",
        ),
    ),
    (
        "Confidence & Models",
        (
            "confidence",
            "uncertain",
            "ensemble",
            "ecmwf",
            "gfs",
            "nam",
            "hrrr",
            "nwp",
            "spread",
            "cluster",
            "consensus",
            "trending",
        ),
    ),
]


def _reflow_paragraph(text: str) -> str:
    """Collapse hard-wrapped 69-column NWS line breaks into readable mobile paragraphs."""
    blocks = re.split(r"\n\s*\n", text.strip())
    cleaned: List[str] = []
    for block in blocks:
        lines = [line.strip() for line in block.splitlines() if line.strip()]
        if not lines:
            continue
        joined = " ".join(lines)
        joined = re.sub(r"\s{2,}", " ", joined)
        cleaned.append(joined)
    return "\n\n".join(cleaned)


def parse_afd_sections(raw_text: str) -> Dict[str, str]:
    matches = list(SECTION_PATTERN.finditer(raw_text))
    sections: Dict[str, str] = {}
    for idx, match in enumerate(matches):
        name = match.group(1).upper()
        start = match.end()
        end = matches[idx + 1].start() if idx + 1 < len(matches) else len(raw_text)
        body = raw_text[start:end]
        # Strip trailing `&&` or `$$`
        body = re.split(r"\n(?:&&|\$\$)", body)[0]
        cleaned = _reflow_paragraph(body)
        if cleaned:
            sections[name] = cleaned
    return sections


def _split_sentences(text: str) -> List[str]:
    # Split on sentence-ending punctuation followed by whitespace + capital/digit.
    parts = re.split(r"(?<=[.!?])\s+(?=[A-Z0-9])", text)
    return [p.strip() for p in parts if len(p.strip()) > 20]


def extract_mountain_highlights(
    sections: Dict[str, str], max_per_category: int = 2
) -> List[MeteorologistHighlight]:
    search_pool = "\n\n".join(
        part
        for key in ("SYNOPSIS", "NEAR TERM", "SHORT TERM", "LONG TERM")
        if (part := sections.get(key))
    )
    if not search_pool:
        return []

    sentences = _split_sentences(search_pool)
    per_category: Dict[str, List[Tuple[int, str]]] = {cat: [] for cat, _ in CATEGORY_KEYWORDS}

    for s in sentences:
        low = s.lower()
        bonus = 2 if any(m in low for m in ("mountain", "summit", "elev", "inch", "upslope")) else 0
        best_cat: Optional[str] = None
        best_hits = 0
        for category, keywords in CATEGORY_KEYWORDS:
            hits = sum(1 for kw in keywords if kw in low)
            if hits > best_hits:
                best_hits = hits
                best_cat = category
        if best_cat is not None and best_hits > 0:
            per_category[best_cat].append((best_hits + bonus, s))

    highlights: List[MeteorologistHighlight] = []
    for category, _ in CATEGORY_KEYWORDS:
        scored = per_category[category]
        scored.sort(key=lambda item: item[0], reverse=True)
        for _, sentence in scored[:max_per_category]:
            highlights.append(MeteorologistHighlight(category=category, summary=sentence))

    return highlights


def build_discussion_model(product: NWSAFDProduct, is_live: bool = True) -> MeteorologistDiscussion:
    wfo_cfg = WFO_OFFICES.get(product.wfo_id)
    wfo_name = wfo_cfg.name if wfo_cfg else f"NWS {product.wfo_id}"
    sections = parse_afd_sections(product.raw_text)
    highlights = extract_mountain_highlights(sections)

    if highlights:
        top_summaries = " ".join(h.summary for h in highlights[:2])
        relevance_summary = top_summaries
    else:
        relevance_summary = (
            sections.get("SYNOPSIS")
            or sections.get("SHORT TERM")
            or "See full National Weather Service technical discussion below."
        )
        if len(relevance_summary) > 320:
            relevance_summary = relevance_summary[:317].rstrip() + "..."

    covered = [m.id for m in NORTHEAST_MOUNTAINS if m.nws_wfo == product.wfo_id]
    short_term = sections.get("SHORT TERM") or sections.get("NEAR TERM")

    return MeteorologistDiscussion(
        wfo_id=product.wfo_id,
        wfo_name=wfo_name,
        issued_at=product.issued_at,
        forecaster=product.forecaster,
        product_id=product.product_id,
        mountain_relevance_summary=relevance_summary,
        highlights=highlights,
        synopsis=sections.get("SYNOPSIS"),
        short_term=short_term,
        long_term=sections.get("LONG TERM"),
        raw_text=product.raw_text,
        covered_mountain_ids=covered,
        is_live=is_live,
    )


def build_offline_fallback_afd(wfo_id: str) -> MeteorologistDiscussion:
    wfo_id = wfo_id.upper()
    sample_text = (
        f"AREA FORECAST DISCUSSION\n"
        f"NATIONAL WEATHER SERVICE {wfo_id}\n\n"
        f".SYNOPSIS...\n"
        f"A progressive northern stream trough crosses New England late tonight, "
        f"ushering colder 850mb air (-10C to -13C) and brisk northwest upslope flow "
        f"into the Green Mountains, White Mountains, and Western Maine peaks.\n\n"
        f".SHORT TERM...\n"
        f"Favorable northwest flow and moisture in the dendritic growth zone will "
        f"support persistent orographic snow showers across higher terrain above 2000 ft. "
        f"High-resolution HRRR and NAM guidance indicate snow ratios climbing toward 14:1 "
        f"to 17:1 on upper slopes, with 3 to 6 inches possible at summit elevations and "
        f"localized higher amounts along favored upslope spines. Ridgetop wind gusts of "
        f"30 to 40 mph may create isolated lift hold concerns on exposed upper chairs.\n\n"
        f".LONG TERM...\n"
        f"Ensemble spread remains moderate beyond day 4 as ECMWF and GFS diverge slightly "
        f"on the track of a coastal wave late week. Confidence is high for below-normal "
        f"temperatures preserving snowpack through mid-week.\n\n"
        f"&&\n$$\nOFFLINE-CACHE\n"
    )
    product = NWSAFDProduct(
        wfo_id=wfo_id,
        product_id=f"offline-{wfo_id.lower()}",
        issued_at=datetime.now(timezone.utc),
        raw_text=sample_text,
        forecaster="Offline Cache",
    )
    return build_discussion_model(product, is_live=False)
