# StreamLD + Riptide Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Author the StreamLD specification's normative data-shape artifacts (SHACL model +
Bikeshed prose) and build Riptide, an Elixir/Phoenix reference implementation that is both a
StreamLD-conformant event log and a minimal LDP/Solid pod server, backed by that log.

**Architecture:** SHACL shapes in `spec/streamld/model/envelope.ttl` are the single source of
truth for every wire-format shape (event envelope, WebSocket replication frame, subscription
request/response, gap signal). A Python generator renders those shapes into Bikeshed
data-dictionary tables (mirroring `mikadiv/`'s existing XSD-driven pipeline) and a derived JSON
Schema (via `shacl2code`). Riptide implements the same shapes as hand-written Elixir structs
(no Elixir SHACL tooling exists yet — see the design doc's §4.4 open item), with one GenServer
per event stream owning sequence assignment, backing both an LDP HTTP surface and two real-time
transport bindings (SSE for clients, a WebSocket channel for server-to-server replication).

**Tech Stack:** Python 3.9+ (`rdflib`, `pyshacl`, `shacl2code`) for spec tooling; Bikeshed for
spec rendering; Elixir/Phoenix (`rdf`, `json_ld`, `jason`) for Riptide.

**Spec:** `docs/superpowers/specs/2026-08-22-streamld-riptide-design.md` (this repo)

## Global Constraints

- Ordering is a strictly increasing, per-stream integer sequence number assigned by the server
  at write time — no timestamp-based ordering anywhere (design doc §4.1-4.2).
- The cursor is the sequence number itself; a gap (cursor aged out of the retention window)
  MUST return an explicit gap signal, never silent resumption from the wrong position (§4.2).
- SHACL, not JSON Schema, is the source of truth for all data shapes; JSON Schema is a derived
  artifact (§4.4).
- First-phase scope excludes: WebID-OIDC auth, WAC/ACP access control, the MQTT transport
  binding, pod provisioning/multi-tenancy (§6). Do not add these.
- Two repos: `spec/` = `OpenFASTER-Standard/spec` (clone alongside this repo), `riptide/` = this
  repo. Tasks state which repo their files belong to.

---

## File Structure

**`spec/streamld/`** (new directory in `OpenFASTER-Standard/spec`):

```
streamld/
├── model/
│   └── envelope.ttl                SHACL shapes: EventEnvelope, ReplicationFrame,
│                                    SubscriptionRequest, GapSignal (source of truth)
├── examples/
│   ├── envelope-valid.jsonld
│   ├── envelope-invalid.jsonld
│   ├── replication-frame-valid.jsonld
│   ├── replication-frame-invalid.jsonld
│   ├── subscription-request-valid.jsonld
│   └── subscription-request-invalid.jsonld
├── tests/
│   ├── requirements.txt
│   ├── test_envelope_shape.py
│   ├── test_other_shapes.py
│   ├── test_shacl_model.py
│   └── test_generate_streamld_docs.py
├── generator/
│   ├── shacl_model.py               Layer 1: SHACL extractor
│   └── generate_streamld_docs.py    Layer 3: renders Bikeshed include + JSON Schema
├── core.bs                          Core spec: envelope, cursor, gap handling
├── binding-sse.bs                   SSE transport binding
├── binding-websocket.bs             WebSocket replication transport binding
├── subscription.bs                  Subscription/discovery spec
└── generated/                       (generated; do not edit by hand)
    ├── fields.include.bs
    └── envelope.schema.json
```

**`riptide/`** (this repo, Phoenix project root):

```
lib/
├── riptide/
│   ├── application.ex
│   ├── event.ex                     Mirrors the EventEnvelope SHACL shape
│   ├── stream/
│   │   ├── stream_server.ex         One GenServer per stream: sequence + retention
│   │   └── stream_supervisor.ex     DynamicSupervisor + Registry lookup
│   └── rdf/
│       ├── turtle_codec.ex          Turtle/JSON-LD (de)serialization wrapper
│       └── patch.ex                 RDF Patch (add/remove triple) application
├── riptide_web/
│   ├── endpoint.ex
│   ├── router.ex
│   ├── ldp/
│   │   └── resource_controller.ex   GET/PUT/POST/DELETE/PATCH on LDP resources
│   └── realtime/
│       ├── sse_controller.ex        SSE endpoint, Last-Event-ID handling
│       └── replication_channel.ex   Phoenix Channel: WebSocket replication binding
test/
├── riptide/
│   ├── event_test.exs
│   ├── stream/stream_server_test.exs
│   ├── stream/stream_supervisor_test.exs
│   └── rdf/
│       ├── turtle_codec_test.exs
│       └── patch_test.exs
└── riptide_web/
    ├── ldp/resource_controller_test.exs
    └── realtime/
        ├── sse_controller_test.exs
        └── replication_channel_test.exs
```

---

### Task 1: SHACL shape for the Event Envelope

**Files:**
- Create: `spec/streamld/model/envelope.ttl`
- Create: `spec/streamld/examples/envelope-valid.jsonld`
- Create: `spec/streamld/examples/envelope-invalid.jsonld`
- Create: `spec/streamld/tests/requirements.txt`
- Test: `spec/streamld/tests/test_envelope_shape.py`

**Interfaces:**
- Produces: the `streamld:EventEnvelopeShape` SHACL shape (namespace
  `https://openfaster.org/streamld#`) with properties `streamld:sequence` (`xsd:integer`,
  required, `sh:minInclusive 1`), `streamld:streamId` (`xsd:string`, required),
  `streamld:isSnapshot` (`xsd:boolean`, required), `streamld:payload` (any node, required).
  Consumed by Task 2 (sibling shapes reference `streamld:EventEnvelope` via `sh:class`), Task 3
  (the SHACL extractor), and Task 7 (`Riptide.Event` mirrors these exact field names).

- [ ] **Step 1: Write the failing test**

```python
# spec/streamld/tests/test_envelope_shape.py
from pathlib import Path

import pytest
from pyshacl import validate
from rdflib import Graph

SHAPES_PATH = str(Path(__file__).parent.parent / "model" / "envelope.ttl")
EXAMPLES_DIR = Path(__file__).parent.parent / "examples"


def _validate(example_filename):
    data_graph = Graph()
    data_graph.parse(str(EXAMPLES_DIR / example_filename), format="json-ld")
    conforms, _, results_text = validate(
        data_graph,
        shacl_graph=SHAPES_PATH,
        data_graph_format="json-ld",
        shacl_graph_format="turtle",
    )
    return conforms, results_text


def test_valid_envelope_conforms():
    conforms, results_text = _validate("envelope-valid.jsonld")
    assert conforms, results_text


def test_invalid_envelope_is_rejected():
    conforms, _ = _validate("envelope-invalid.jsonld")
    assert not conforms
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd spec/streamld/tests && pip install -r requirements.txt && pytest test_envelope_shape.py -v`
Expected: FAIL — `model/envelope.ttl` does not exist yet (`FileNotFoundError` inside `pyshacl`,
or an `rdflib` parse error on the missing/empty examples).

- [ ] **Step 3: Write the SHACL shape and the two example documents**

```turtle
# spec/streamld/model/envelope.ttl
@prefix sh: <http://www.w3.org/ns/shacl#> .
@prefix xsd: <http://www.w3.org/2001/XMLSchema#> .
@prefix streamld: <https://openfaster.org/streamld#> .

streamld:EventEnvelopeShape
    a sh:NodeShape ;
    sh:targetClass streamld:EventEnvelope ;
    sh:property [
        sh:path streamld:sequence ;
        sh:datatype xsd:integer ;
        sh:minCount 1 ;
        sh:maxCount 1 ;
        sh:minInclusive 1 ;
    ] ;
    sh:property [
        sh:path streamld:streamId ;
        sh:datatype xsd:string ;
        sh:minCount 1 ;
        sh:maxCount 1 ;
    ] ;
    sh:property [
        sh:path streamld:isSnapshot ;
        sh:datatype xsd:boolean ;
        sh:minCount 1 ;
        sh:maxCount 1 ;
    ] ;
    sh:property [
        sh:path streamld:payload ;
        sh:minCount 1 ;
        sh:maxCount 1 ;
    ] .
```

```json
// spec/streamld/examples/envelope-valid.jsonld
{
  "@context": {
    "streamld": "https://openfaster.org/streamld#",
    "sequence": { "@id": "streamld:sequence", "@type": "xsd:integer" },
    "streamId": "streamld:streamId",
    "isSnapshot": { "@id": "streamld:isSnapshot", "@type": "xsd:boolean" },
    "payload": { "@id": "streamld:payload", "@type": "@id" },
    "xsd": "http://www.w3.org/2001/XMLSchema#"
  },
  "@type": "streamld:EventEnvelope",
  "sequence": 1,
  "streamId": "https://pod.example/alice/profile",
  "isSnapshot": true,
  "payload": "https://pod.example/alice/profile#me"
}
```

```json
// spec/streamld/examples/envelope-invalid.jsonld
{
  "@context": {
    "streamld": "https://openfaster.org/streamld#",
    "sequence": { "@id": "streamld:sequence", "@type": "xsd:integer" },
    "isSnapshot": { "@id": "streamld:isSnapshot", "@type": "xsd:boolean" },
    "xsd": "http://www.w3.org/2001/XMLSchema#"
  },
  "@type": "streamld:EventEnvelope",
  "sequence": 0,
  "isSnapshot": true
}
```

(The invalid example violates the shape three ways: `sequence` is `0`, below
`sh:minInclusive 1`; `streamId` is missing entirely; `payload` is missing entirely.)

```
# spec/streamld/tests/requirements.txt
pyshacl==0.40.1
rdflib>=7.0
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd spec/streamld/tests && pytest test_envelope_shape.py -v`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
cd spec
git add streamld/model/envelope.ttl streamld/examples/envelope-valid.jsonld \
  streamld/examples/envelope-invalid.jsonld streamld/tests/requirements.txt \
  streamld/tests/test_envelope_shape.py
git commit -m "streamld: add EventEnvelope SHACL shape and conformance tests"
```

---

### Task 2: SHACL shapes for ReplicationFrame, SubscriptionRequest, and GapSignal

**Files:**
- Modify: `spec/streamld/model/envelope.ttl` (append three more shapes)
- Create: `spec/streamld/examples/replication-frame-valid.jsonld`
- Create: `spec/streamld/examples/replication-frame-invalid.jsonld`
- Create: `spec/streamld/examples/subscription-request-valid.jsonld`
- Create: `spec/streamld/examples/subscription-request-invalid.jsonld`
- Test: `spec/streamld/tests/test_other_shapes.py`

**Interfaces:**
- Consumes: `streamld:EventEnvelope` (Task 1) via `sh:class` on `ReplicationFrame`'s `event`
  property.
- Produces: `streamld:ReplicationFrameShape` (`streamld:cursor` xsd:integer required,
  `streamld:event` required node of class `streamld:EventEnvelope`),
  `streamld:SubscriptionRequestShape` (`streamld:stream` IRI required, `streamld:after`
  xsd:integer optional), `streamld:GapSignalShape` (`streamld:oldestAvailable` xsd:integer
  optional). Consumed by Task 3 (extractor) and Tasks 14/16 (Riptide's SSE/WebSocket handlers
  use these exact field names).

- [ ] **Step 1: Write the failing test**

```python
# spec/streamld/tests/test_other_shapes.py
from pathlib import Path

from pyshacl import validate
from rdflib import Graph

SHAPES_PATH = str(Path(__file__).parent.parent / "model" / "envelope.ttl")
EXAMPLES_DIR = Path(__file__).parent.parent / "examples"


def _validate(example_filename):
    data_graph = Graph()
    data_graph.parse(str(EXAMPLES_DIR / example_filename), format="json-ld")
    conforms, _, results_text = validate(
        data_graph,
        shacl_graph=SHAPES_PATH,
        data_graph_format="json-ld",
        shacl_graph_format="turtle",
    )
    return conforms, results_text


def test_valid_replication_frame_conforms():
    conforms, results_text = _validate("replication-frame-valid.jsonld")
    assert conforms, results_text


def test_invalid_replication_frame_is_rejected():
    conforms, _ = _validate("replication-frame-invalid.jsonld")
    assert not conforms


def test_valid_subscription_request_conforms():
    conforms, results_text = _validate("subscription-request-valid.jsonld")
    assert conforms, results_text


def test_invalid_subscription_request_is_rejected():
    conforms, _ = _validate("subscription-request-invalid.jsonld")
    assert not conforms
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd spec/streamld/tests && pytest test_other_shapes.py -v`
Expected: FAIL — the three new shapes and the four new example files don't exist yet.

- [ ] **Step 3: Append the shapes and write the examples**

```turtle
# Append to spec/streamld/model/envelope.ttl

streamld:ReplicationFrameShape
    a sh:NodeShape ;
    sh:targetClass streamld:ReplicationFrame ;
    sh:property [
        sh:path streamld:cursor ;
        sh:datatype xsd:integer ;
        sh:minCount 1 ;
        sh:maxCount 1 ;
        sh:minInclusive 0 ;
    ] ;
    sh:property [
        sh:path streamld:event ;
        sh:class streamld:EventEnvelope ;
        sh:minCount 1 ;
        sh:maxCount 1 ;
    ] .

streamld:SubscriptionRequestShape
    a sh:NodeShape ;
    sh:targetClass streamld:SubscriptionRequest ;
    sh:property [
        sh:path streamld:stream ;
        sh:nodeKind sh:IRI ;
        sh:minCount 1 ;
        sh:maxCount 1 ;
    ] ;
    sh:property [
        sh:path streamld:after ;
        sh:datatype xsd:integer ;
        sh:minCount 0 ;
        sh:maxCount 1 ;
        sh:minInclusive 0 ;
    ] .

streamld:GapSignalShape
    a sh:NodeShape ;
    sh:targetClass streamld:GapSignal ;
    sh:property [
        sh:path streamld:oldestAvailable ;
        sh:datatype xsd:integer ;
        sh:minCount 0 ;
        sh:maxCount 1 ;
    ] .
```

```json
// spec/streamld/examples/replication-frame-valid.jsonld
{
  "@context": {
    "streamld": "https://openfaster.org/streamld#",
    "cursor": { "@id": "streamld:cursor", "@type": "xsd:integer" },
    "event": { "@id": "streamld:event", "@type": "@id" },
    "xsd": "http://www.w3.org/2001/XMLSchema#"
  },
  "@type": "streamld:ReplicationFrame",
  "cursor": 5,
  "event": {
    "@id": "https://pod.example/alice/profile/events/5",
    "@type": "streamld:EventEnvelope",
    "sequence": 5,
    "streamId": "https://pod.example/alice/profile",
    "isSnapshot": false,
    "payload": "https://pod.example/alice/profile#me"
  }
}
```

```json
// spec/streamld/examples/replication-frame-invalid.jsonld
{
  "@context": {
    "streamld": "https://openfaster.org/streamld#",
    "cursor": { "@id": "streamld:cursor", "@type": "xsd:integer" },
    "xsd": "http://www.w3.org/2001/XMLSchema#"
  },
  "@type": "streamld:ReplicationFrame",
  "cursor": -1
}
```

```json
// spec/streamld/examples/subscription-request-valid.jsonld
{
  "@context": {
    "streamld": "https://openfaster.org/streamld#",
    "stream": { "@id": "streamld:stream", "@type": "@id" },
    "after": { "@id": "streamld:after", "@type": "xsd:integer" },
    "xsd": "http://www.w3.org/2001/XMLSchema#"
  },
  "@type": "streamld:SubscriptionRequest",
  "stream": "https://pod.example/alice/profile",
  "after": 5
}
```

```json
// spec/streamld/examples/subscription-request-invalid.jsonld
{
  "@context": {
    "streamld": "https://openfaster.org/streamld#",
    "after": { "@id": "streamld:after", "@type": "xsd:integer" },
    "xsd": "http://www.w3.org/2001/XMLSchema#"
  },
  "@type": "streamld:SubscriptionRequest",
  "after": 5
}
```

(The subscription-request-invalid example omits the required `streamld:stream`.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd spec/streamld/tests && pytest test_other_shapes.py -v`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
cd spec
git add streamld/model/envelope.ttl streamld/examples/ streamld/tests/test_other_shapes.py
git commit -m "streamld: add ReplicationFrame, SubscriptionRequest, GapSignal shapes"
```

---

### Task 3: SHACL extractor (`shacl_model.py`)

**Files:**
- Create: `spec/streamld/generator/__init__.py` (empty)
- Create: `spec/streamld/generator/shacl_model.py`
- Test: `spec/streamld/tests/test_shacl_model.py`
- Modify: `spec/streamld/tests/requirements.txt` (no new deps — `rdflib` already present)

**Interfaces:**
- Consumes: `spec/streamld/model/envelope.ttl` (Tasks 1-2).
- Produces: `Field` (dataclass: `name: str`, `datatype: str | None`, `min_count: int`,
  `max_count: int | None`), `load_shapes(path: str) -> rdflib.Graph`,
  `fields_for_shape(graph: rdflib.Graph, shape_iri) -> list[Field]` (sorted by `name`). Consumed
  by Task 4's `generate_streamld_docs.py`.

- [ ] **Step 1: Write the failing test**

```python
# spec/streamld/tests/test_shacl_model.py
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from rdflib import Namespace

from generator.shacl_model import Field, fields_for_shape, load_shapes

STREAMLD = Namespace("https://openfaster.org/streamld#")
SHAPES_PATH = str(Path(__file__).parent.parent / "model" / "envelope.ttl")


def test_fields_for_event_envelope_shape():
    graph = load_shapes(SHAPES_PATH)

    fields = fields_for_shape(graph, STREAMLD.EventEnvelopeShape)

    names = [f.name for f in fields]
    assert names == sorted(names)
    assert Field(name="isSnapshot", datatype="boolean", min_count=1, max_count=1) in fields
    assert Field(name="sequence", datatype="integer", min_count=1, max_count=1) in fields
    assert Field(name="streamId", datatype="string", min_count=1, max_count=1) in fields
    assert Field(name="payload", datatype=None, min_count=1, max_count=1) in fields


def test_fields_for_subscription_request_shape_has_optional_after():
    graph = load_shapes(SHAPES_PATH)

    fields = fields_for_shape(graph, STREAMLD.SubscriptionRequestShape)

    after_field = next(f for f in fields if f.name == "after")
    assert after_field.min_count == 0
    assert after_field.max_count == 1
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd spec/streamld/tests && pytest test_shacl_model.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'generator'`

- [ ] **Step 3: Write the minimal implementation**

```python
# spec/streamld/generator/shacl_model.py
"""Layer 1: SHACL extractor. Mirrors engine/xsd_model.py's role for mikadiv/:
parses a SHACL shapes file and answers "what fields does shape X have, with
what type/cardinality?" No hand-typed content — everything is read from the
shapes graph.
"""
from __future__ import annotations

from dataclasses import dataclass

from rdflib import Graph
from rdflib.namespace import SH


@dataclass(frozen=True)
class Field:
    name: str
    datatype: str | None
    min_count: int
    max_count: int | None


def load_shapes(path: str) -> Graph:
    graph = Graph()
    graph.parse(path, format="turtle")
    return graph


def fields_for_shape(graph: Graph, shape_iri) -> list[Field]:
    fields = []
    for prop_bnode in graph.objects(shape_iri, SH.property):
        path = graph.value(prop_bnode, SH.path)
        datatype = graph.value(prop_bnode, SH.datatype)
        min_count = graph.value(prop_bnode, SH.minCount)
        max_count = graph.value(prop_bnode, SH.maxCount)

        fields.append(
            Field(
                name=str(path).rsplit("#", maxsplit=1)[-1],
                datatype=str(datatype).rsplit("#", maxsplit=1)[-1] if datatype else None,
                min_count=int(min_count) if min_count is not None else 0,
                max_count=int(max_count) if max_count is not None else None,
            )
        )
    return sorted(fields, key=lambda f: f.name)
```

```python
# spec/streamld/generator/__init__.py
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd spec/streamld/tests && pytest test_shacl_model.py -v`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
cd spec
git add streamld/generator/__init__.py streamld/generator/shacl_model.py \
  streamld/tests/test_shacl_model.py
git commit -m "streamld: add SHACL extractor (shacl_model.py)"
```

---

### Task 4: Bikeshed include + JSON Schema generator (`generate_streamld_docs.py`)

**Files:**
- Create: `spec/streamld/generator/generate_streamld_docs.py`
- Modify: `spec/streamld/tests/requirements.txt` (no new deps needed for the testable part;
  `shacl2code` is invoked as a subprocess, not imported)
- Test: `spec/streamld/tests/test_generate_streamld_docs.py`

**Interfaces:**
- Consumes: `load_shapes`, `fields_for_shape` (Task 3).
- Produces: `render_bikeshed_include(model_path: str) -> str`, `generate_json_schema(model_path:
  str, output_path: str) -> None`, `main() -> None`. Consumed by Task 5 (the rendered include is
  what `core.bs` pulls in via Bikeshed's `<pre class=include>`).

- [ ] **Step 1: Write the failing test**

```python
# spec/streamld/tests/test_generate_streamld_docs.py
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from generator.generate_streamld_docs import render_bikeshed_include

SHAPES_PATH = str(Path(__file__).parent.parent / "model" / "envelope.ttl")


def test_render_bikeshed_include_contains_all_shapes():
    output = render_bikeshed_include(SHAPES_PATH)

    assert "### EventEnvelope ###" in output
    assert "`sequence`" in output
    assert "`isSnapshot`" in output
    assert "### ReplicationFrame ###" in output
    assert "### SubscriptionRequest ###" in output
    assert "### GapSignal ###" in output


def test_render_bikeshed_include_marks_required_fields():
    output = render_bikeshed_include(SHAPES_PATH)

    lines = output.splitlines()
    sequence_line = next(line for line in lines if "`sequence`" in line)
    after_line = next(line for line in lines if "`after`" in line)

    assert "| Yes |" in sequence_line
    assert "| No |" in after_line
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd spec/streamld/tests && pytest test_generate_streamld_docs.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'generator.generate_streamld_docs'`

- [ ] **Step 3: Write the minimal implementation**

```python
# spec/streamld/generator/generate_streamld_docs.py
"""Build entry point: SHACL -> Bikeshed data-dictionary include + derived JSON
Schema. Mirrors generate_template.py's role for mikadiv/, but for SHACL
instead of XSD.
"""
from __future__ import annotations

import subprocess
from pathlib import Path

from rdflib import Namespace

from generator.shacl_model import fields_for_shape, load_shapes

STREAMLD = Namespace("https://openfaster.org/streamld#")

SHAPES = {
    "EventEnvelope": STREAMLD.EventEnvelopeShape,
    "ReplicationFrame": STREAMLD.ReplicationFrameShape,
    "SubscriptionRequest": STREAMLD.SubscriptionRequestShape,
    "GapSignal": STREAMLD.GapSignalShape,
}


def render_bikeshed_include(model_path: str) -> str:
    graph = load_shapes(model_path)
    lines = ["<!-- Generated from streamld/model/envelope.ttl. Do not edit by hand. -->", ""]

    for shape_name, shape_iri in SHAPES.items():
        lines.append(f"### {shape_name} ### {{#{shape_name.lower()}-fields}}")
        lines.append("")
        lines.append("| Field | Type | Required |")
        lines.append("| --- | --- | --- |")
        for field in fields_for_shape(graph, shape_iri):
            required = "Yes" if field.min_count >= 1 else "No"
            lines.append(f"| `{field.name}` | {field.datatype or '(node)'} | {required} |")
        lines.append("")

    return "\n".join(lines)


def generate_json_schema(model_path: str, output_path: str) -> None:
    subprocess.run(
        ["shacl2code", "generate", "-i", model_path, "jsonschema", "-o", output_path],
        check=True,
    )


def main() -> None:
    model_path = "streamld/model/envelope.ttl"
    generated_dir = Path("streamld/generated")
    generated_dir.mkdir(parents=True, exist_ok=True)

    (generated_dir / "fields.include.bs").write_text(render_bikeshed_include(model_path))
    generate_json_schema(model_path, str(generated_dir / "envelope.schema.json"))


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd spec/streamld/tests && pytest test_generate_streamld_docs.py -v`
Expected: PASS (2 tests)

- [ ] **Step 5: Run the generator for real and commit**

```bash
cd spec
pip install shacl2code==1.2.0
python -m streamld.generator.generate_streamld_docs  # or: cd streamld && python generator/generate_streamld_docs.py
git add streamld/generator/generate_streamld_docs.py streamld/tests/test_generate_streamld_docs.py \
  streamld/generated/
git commit -m "streamld: add Bikeshed include + JSON Schema generator"
```

---

### Task 5: Author `core.bs` and build it

**Files:**
- Create: `spec/streamld/core.bs`
- Test: (Bikeshed build itself is the test — no separate test file; Bikeshed is already a
  project dependency per `spec/documentation/requirements-spec.txt`)

**Interfaces:**
- Consumes: `spec/streamld/generated/fields.include.bs` (Task 4).
- Produces: `spec/streamld/core.html` (built artifact) documenting the envelope shape, the
  cursor model, and gap-handling conformance requirements — this is what Tasks 14-16's Elixir
  code implements against.

- [ ] **Step 1: Write `core.bs`**

```html
<pre class='metadata'>
Title: StreamLD Core
Shortname: streamld-core
Level: 1
Status: w3c/CG-DRAFT
Group: openfaster
URL: https://openfaster.org/streamld/core.html
Editor: OpenFASTER Editors
Abstract: StreamLD is a protocol for real-time, resumable Linked Data event streaming. This document defines the core event envelope and cursor model that every StreamLD transport binding builds on.
</pre>

# Introduction # {#intro}

StreamLD defines an append-only, per-stream event log. Each event is assigned a
*sequence number* by the server at write time: a strictly increasing, per-stream
integer starting at 1. Sequence numbers are the sole ordering primitive — StreamLD
defines no timestamp-based ordering.

# The Event Envelope # {#envelope}

Every StreamLD event is a `streamld:EventEnvelope`. Its normative field list is
defined by the SHACL shape at `streamld/model/envelope.ttl` and summarized below.

<div class="note">
The table below is generated from <code>streamld/model/envelope.ttl</code> by
<code>generator/generate_streamld_docs.py</code>. Do not edit it by hand — edit
the SHACL shape and regenerate.
</div>

<pre class=include>
path: generated/fields.include.bs
</pre>

# The Cursor # {#cursor}

A StreamLD *cursor* is a sequence number: the position of the last event a
subscriber has already received. A subscription request of the form "everything
after cursor C" MUST be interpreted as "all events with sequence number greater
than C, in ascending sequence order."

## Gap handling ## {#gap-handling}

If a server can no longer satisfy a subscription request because the requested
cursor has aged out of the stream's retention window, it MUST respond with a
`streamld:GapSignal` rather than silently resuming from an incorrect position. A
client that receives a `streamld:GapSignal` MUST perform a full historical read
of the stream before re-subscribing live.

# Conformance # {#conformance}

A StreamLD-conformant server MUST:

* Assign sequence numbers as a strictly increasing, per-stream integer sequence
  starting at 1, with no gaps in the sequence for events actually appended.
* Reject a subscription request whose `streamld:after` cursor is not resolvable
  against the stream's current retention window by responding with a
  `streamld:GapSignal`, never by silently omitting events.
```

- [ ] **Step 2: Build it and verify it compiles cleanly**

Run: `cd spec/streamld && bikeshed --allow-nonlocal-files --die-on=link-error spec core.bs core.html`
Expected: exits 0, `core.html` is created, and contains the strings `EventEnvelope`,
`sequence`, and `GapSignal` (spot check: `grep -c "GapSignal" core.html` returns a number > 0).

- [ ] **Step 3: Commit**

```bash
cd spec
git add streamld/core.bs streamld/core.html
git commit -m "streamld: author and build core.bs"
```

---

### Task 6: Scaffold the Riptide Phoenix project

**Files:**
- Create: `mix.exs`
- Create: `lib/riptide/application.ex`
- Create: `lib/riptide_web/endpoint.ex`
- Create: `lib/riptide_web/router.ex`
- Test: `test/riptide_web/health_test.exs`

**Interfaces:**
- Produces: a booting Phoenix application named `Riptide` / `RiptideWeb`, with `GET /health`
  returning `200 "ok"`. Consumed by every later task, which extends `router.ex` and
  `application.ex`'s supervision tree.

- [ ] **Step 1: Scaffold with `mix phx.new`**

Run (from the parent directory containing this repo, replacing the generated dir contents into
the existing git repo):

```bash
mix phx.new riptide_scaffold --no-ecto --no-html --no-assets --no-mailer --no-dashboard
rsync -a --exclude='.git' riptide_scaffold/ riptide/
rm -rf riptide_scaffold
```

Edit the generated `mix.exs` app name/module to `:riptide` / `Riptide` if `mix phx.new` did not
already infer it from the target directory name.

```elixir
# mix.exs
defmodule Riptide.MixProject do
  use Mix.Project

  def project do
    [
      app: :riptide,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Riptide.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},
      {:rdf, "~> 3.0"},
      {:json_ld, "~> 1.0"}
    ]
  end
end
```

- [ ] **Step 2: Write the failing test**

```elixir
# test/riptide_web/health_test.exs
defmodule RiptideWeb.HealthTest do
  use ExUnit.Case, async: true
  use Plug.Test

  @opts RiptideWeb.Endpoint.init([])

  test "GET /health returns 200 ok" do
    conn =
      :get
      |> conn("/health")
      |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 200
    assert conn.resp_body == "ok"
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix deps.get && mix test test/riptide_web/health_test.exs`
Expected: FAIL — no route for `/health` yet (404, not 200).

- [ ] **Step 4: Add the route**

```elixir
# lib/riptide_web/router.ex
defmodule RiptideWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json", "turtle", "ld+json"]
  end

  scope "/" do
    pipe_through :api

    get "/health", RiptideWeb.HealthController, :show
  end
end
```

```elixir
# lib/riptide_web/health_controller.ex
defmodule RiptideWeb.HealthController do
  use Phoenix.Controller

  def show(conn, _params) do
    send_resp(conn, 200, "ok")
  end
end
```

Ensure `lib/riptide_web/endpoint.ex` (generated by `mix phx.new`) plugs `RiptideWeb.Router` and
`lib/riptide/application.ex` starts `RiptideWeb.Endpoint` in its supervision tree — both are
generated correctly by `mix phx.new --no-html --no-assets` by default; verify by reading the
generated files rather than rewriting them.

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/riptide_web/health_test.exs`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add mix.exs mix.lock lib/ test/ config/
git commit -m "riptide: scaffold Phoenix project with a health endpoint"
```

---

### Task 7: `Riptide.Event` struct

**Files:**
- Create: `lib/riptide/event.ex`
- Test: `test/riptide/event_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces: `%Riptide.Event{sequence: pos_integer() | nil, stream_id: String.t(), is_snapshot?:
  boolean(), payload: RDF.Graph.t()}`, `Riptide.Event.new/3`, `Riptide.Event.with_sequence/2`.
  Field names mirror `streamld:EventEnvelope` (Task 1) exactly: `sequence`, `stream_id` (⟶
  `streamId`), `is_snapshot?` (⟶ `isSnapshot`), `payload`. Consumed by Task 8
  (`Riptide.Stream.StreamServer.append/2`).

- [ ] **Step 1: Write the failing test**

```elixir
# test/riptide/event_test.exs
defmodule Riptide.EventTest do
  use ExUnit.Case, async: true

  test "new/3 builds an event with sequence unset" do
    graph = RDF.Graph.new()
    event = Riptide.Event.new("https://pod.example/alice/profile", graph)

    assert event.stream_id == "https://pod.example/alice/profile"
    assert event.payload == graph
    assert event.is_snapshot? == false
    assert event.sequence == nil
  end

  test "new/3 accepts an explicit is_snapshot? flag" do
    event = Riptide.Event.new("stream-1", RDF.Graph.new(), true)

    assert event.is_snapshot? == true
  end

  test "with_sequence/2 assigns a sequence number" do
    event = Riptide.Event.new("stream-1", RDF.Graph.new())
    updated = Riptide.Event.with_sequence(event, 42)

    assert updated.sequence == 42
  end

  test "with_sequence/2 rejects non-positive integers" do
    event = Riptide.Event.new("stream-1", RDF.Graph.new())

    assert_raise FunctionClauseError, fn ->
      Riptide.Event.with_sequence(event, 0)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/riptide/event_test.exs`
Expected: FAIL — `Riptide.Event` module does not exist.

- [ ] **Step 3: Write the minimal implementation**

```elixir
# lib/riptide/event.ex
defmodule Riptide.Event do
  @moduledoc """
  Mirrors the StreamLD EventEnvelope SHACL shape
  (spec/streamld/model/envelope.ttl): sequence, stream_id, is_snapshot?, payload.
  """

  @enforce_keys [:stream_id, :payload]
  defstruct [:sequence, :stream_id, :is_snapshot?, :payload]

  @type t :: %__MODULE__{
          sequence: pos_integer() | nil,
          stream_id: String.t(),
          is_snapshot?: boolean(),
          payload: RDF.Graph.t()
        }

  @spec new(String.t(), RDF.Graph.t(), boolean()) :: t()
  def new(stream_id, payload, is_snapshot? \\ false) do
    %__MODULE__{stream_id: stream_id, payload: payload, is_snapshot?: is_snapshot?}
  end

  @spec with_sequence(t(), pos_integer()) :: t()
  def with_sequence(%__MODULE__{} = event, sequence)
      when is_integer(sequence) and sequence > 0 do
    %{event | sequence: sequence}
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/riptide/event_test.exs`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/riptide/event.ex test/riptide/event_test.exs
git commit -m "riptide: add Riptide.Event struct"
```

---

### Task 8: `Riptide.Stream.StreamServer` (sequence assignment + retrieval)

**Files:**
- Create: `lib/riptide/stream/stream_server.ex`
- Test: `test/riptide/stream/stream_server_test.exs`

**Interfaces:**
- Consumes: `Riptide.Event.new/3`, `Riptide.Event.with_sequence/2` (Task 7).
- Produces: `Riptide.Stream.StreamServer.start_link/1`, `Riptide.Stream.StreamServer.via/1`,
  `append/2 :: (stream_id :: String.t(), Riptide.Event.t()) -> Riptide.Event.t()`, `get_since/2
  :: (stream_id :: String.t(), cursor :: non_neg_integer() | nil) -> {:ok, [Riptide.Event.t()]}
  | {:gap, pos_integer() | nil}`. Consumed by Task 9 (supervision), Task 12 (LDP writes), Tasks
  14/16 (subscription reads).
- Note: this task starts servers directly via `start_link/1` in its own tests (no registry
  wiring yet — that's Task 9). Each test uses a unique stream ID to avoid `:already_started`
  collisions across the `async: true` test process registry.

- [ ] **Step 1: Write the failing test**

```elixir
# test/riptide/stream/stream_server_test.exs
defmodule Riptide.Stream.StreamServerTest do
  use ExUnit.Case, async: true

  alias Riptide.Event
  alias Riptide.Stream.StreamServer

  setup do
    stream_id = "stream-#{System.unique_integer([:positive])}"
    start_supervised!({StreamServer, stream_id})
    {:ok, stream_id: stream_id}
  end

  test "append/2 assigns sequence numbers starting at 1", %{stream_id: stream_id} do
    event = Event.new(stream_id, RDF.Graph.new())

    appended = StreamServer.append(stream_id, event)

    assert appended.sequence == 1
  end

  test "append/2 assigns strictly increasing sequence numbers", %{stream_id: stream_id} do
    first = StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))
    second = StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))

    assert first.sequence == 1
    assert second.sequence == 2
  end

  test "get_since/2 with nil cursor returns no historical events (live-tail semantics)", %{
    stream_id: stream_id
  } do
    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))

    assert {:ok, []} = StreamServer.get_since(stream_id, nil)
  end

  test "get_since/2 returns events after the given cursor, in order", %{stream_id: stream_id} do
    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))
    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))
    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))

    {:ok, events} = StreamServer.get_since(stream_id, 1)

    assert Enum.map(events, & &1.sequence) == [2, 3]
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/riptide/stream/stream_server_test.exs`
Expected: FAIL — `Riptide.Stream.StreamServer` module does not exist.

- [ ] **Step 3: Write the minimal implementation**

```elixir
# lib/riptide/stream/stream_server.ex
defmodule Riptide.Stream.StreamServer do
  @moduledoc """
  One GenServer per stream. Owns sequence assignment (serializing writes
  without external locking) and holds the in-memory event log for that
  stream.
  """
  use GenServer

  alias Riptide.Event

  def start_link(stream_id) do
    GenServer.start_link(__MODULE__, stream_id, name: via(stream_id))
  end

  def via(stream_id) do
    {:via, Registry, {Riptide.Stream.Registry, stream_id}}
  end

  @spec append(String.t(), Event.t()) :: Event.t()
  def append(stream_id, %Event{} = event) do
    GenServer.call(via(stream_id), {:append, event})
  end

  @spec get_since(String.t(), non_neg_integer() | nil) ::
          {:ok, [Event.t()]} | {:gap, pos_integer() | nil}
  def get_since(stream_id, cursor) do
    GenServer.call(via(stream_id), {:get_since, cursor})
  end

  @impl true
  def init(stream_id) do
    {:ok, %{stream_id: stream_id, next_sequence: 1, events: []}}
  end

  @impl true
  def handle_call({:append, event}, _from, state) do
    stamped = Event.with_sequence(event, state.next_sequence)
    new_state = %{state | next_sequence: state.next_sequence + 1, events: state.events ++ [stamped]}
    {:reply, stamped, new_state}
  end

  def handle_call({:get_since, nil}, _from, state) do
    {:reply, {:ok, []}, state}
  end

  def handle_call({:get_since, cursor}, _from, state) do
    oldest = List.first(state.events) |> then(&(&1 && &1.sequence))

    if oldest != nil and cursor < oldest - 1 do
      {:reply, {:gap, oldest}, state}
    else
      matching = Enum.filter(state.events, &(&1.sequence > cursor))
      {:reply, {:ok, matching}, state}
    end
  end
end
```

This task requires a `Riptide.Stream.Registry` to exist for `via/1` to work — `start_supervised!`
in the test above starts *only* `StreamServer`, so `test_helper.exs` must also start the
registry for the whole test suite. Add this now:

```elixir
# test/test_helper.exs
{:ok, _} = Registry.start_link(keys: :unique, name: Riptide.Stream.Registry)
ExUnit.start()
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/riptide/stream/stream_server_test.exs`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/riptide/stream/stream_server.ex test/riptide/stream/stream_server_test.exs \
  test/test_helper.exs
git commit -m "riptide: add StreamServer with sequence assignment and get_since/2"
```

---

### Task 9: `Riptide.Stream.StreamSupervisor` + application wiring

**Files:**
- Create: `lib/riptide/stream/stream_supervisor.ex`
- Modify: `lib/riptide/application.ex`
- Modify: `test/test_helper.exs` (remove the manual `Registry.start_link` — the application
  supervision tree now starts it)
- Test: `test/riptide/stream/stream_supervisor_test.exs`

**Interfaces:**
- Consumes: `Riptide.Stream.StreamServer` (Task 8).
- Produces: `Riptide.Stream.StreamSupervisor.get_or_start/1 :: (stream_id :: String.t()) ->
  pid()`. Consumed by Task 12 (`ResourceController` calls this before `StreamServer.append/2`)
  and Tasks 14/16 (subscription handlers call this before `StreamServer.get_since/2`).

- [ ] **Step 1: Write the failing test**

```elixir
# test/riptide/stream/stream_supervisor_test.exs
defmodule Riptide.Stream.StreamSupervisorTest do
  use ExUnit.Case, async: true

  alias Riptide.Stream.StreamSupervisor

  test "get_or_start/1 starts a new process for an unseen stream id" do
    stream_id = "stream-#{System.unique_integer([:positive])}"

    pid = StreamSupervisor.get_or_start(stream_id)

    assert Process.alive?(pid)
  end

  test "get_or_start/1 returns the same pid for the same stream id" do
    stream_id = "stream-#{System.unique_integer([:positive])}"

    first = StreamSupervisor.get_or_start(stream_id)
    second = StreamSupervisor.get_or_start(stream_id)

    assert first == second
  end

  test "get_or_start/1 isolates state between different streams" do
    stream_a = "stream-#{System.unique_integer([:positive])}"
    stream_b = "stream-#{System.unique_integer([:positive])}"
    StreamSupervisor.get_or_start(stream_a)
    StreamSupervisor.get_or_start(stream_b)

    Riptide.Stream.StreamServer.append(stream_a, Riptide.Event.new(stream_a, RDF.Graph.new()))

    {:ok, events_b} = Riptide.Stream.StreamServer.get_since(stream_b, 0)
    assert events_b == []
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/riptide/stream/stream_supervisor_test.exs`
Expected: FAIL — `Riptide.Stream.StreamSupervisor` module does not exist, and (once that's
fixed in isolation) the application's Registry isn't started outside of `test_helper.exs`.

- [ ] **Step 3: Write the minimal implementation**

```elixir
# lib/riptide/stream/stream_supervisor.ex
defmodule Riptide.Stream.StreamSupervisor do
  use DynamicSupervisor

  alias Riptide.Stream.StreamServer

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec get_or_start(String.t()) :: pid()
  def get_or_start(stream_id) do
    case Registry.lookup(Riptide.Stream.Registry, stream_id) do
      [{pid, _}] ->
        pid

      [] ->
        case DynamicSupervisor.start_child(__MODULE__, {StreamServer, stream_id}) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end
end
```

```elixir
# lib/riptide/application.ex
defmodule Riptide.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Riptide.Stream.Registry},
      Riptide.Stream.StreamSupervisor,
      RiptideWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Riptide.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

```elixir
# test/test_helper.exs
ExUnit.start()
```

(The `Registry.start_link` manual call from Task 8 is removed — `ExUnit` now boots the full
`:riptide` OTP application, per `mix.exs`'s `mod: {Riptide.Application, []}`, which starts the
registry as part of the normal supervision tree before any test runs.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test`
Expected: PASS (all tests so far, including Task 8's, still green)

- [ ] **Step 5: Commit**

```bash
git add lib/riptide/stream/stream_supervisor.ex lib/riptide/application.ex \
  test/riptide/stream/stream_supervisor_test.exs test/test_helper.exs
git commit -m "riptide: add StreamSupervisor and wire streams into the application tree"
```

---

### Task 10: `Riptide.RDF.TurtleCodec`

**Files:**
- Create: `lib/riptide/rdf/turtle_codec.ex`
- Test: `test/riptide/rdf/turtle_codec_test.exs`

**Interfaces:**
- Consumes: `RDF.Graph`, `RDF.Turtle` (the `rdf` hex package, already a dependency per Task 6).
- Produces: `Riptide.RDF.TurtleCodec.decode(String.t()) :: {:ok, RDF.Graph.t()} | {:error,
  term()}`, `Riptide.RDF.TurtleCodec.encode(RDF.Graph.t()) :: {:ok, String.t()} | {:error,
  term()}`. Consumed by Task 12 (`ResourceController` parses request bodies and serializes
  response bodies through this module).

- [ ] **Step 1: Write the failing test**

```elixir
# test/riptide/rdf/turtle_codec_test.exs
defmodule Riptide.RDF.TurtleCodecTest do
  use ExUnit.Case, async: true

  alias Riptide.RDF.TurtleCodec

  test "decode/1 parses valid Turtle into an RDF.Graph" do
    turtle = """
    @prefix ex: <https://pod.example/> .
    ex:alice ex:name "Alice" .
    """

    assert {:ok, graph} = TurtleCodec.decode(turtle)
    assert RDF.Graph.include?(graph, {RDF.iri("https://pod.example/alice"),
                                       RDF.iri("https://pod.example/name"),
                                       RDF.literal("Alice")})
  end

  test "decode/1 returns an error for invalid Turtle" do
    assert {:error, _reason} = TurtleCodec.decode("this is not turtle {{{")
  end

  test "encode/1 round-trips a graph back to parseable Turtle" do
    {:ok, graph} =
      TurtleCodec.decode("""
      @prefix ex: <https://pod.example/> .
      ex:alice ex:name "Alice" .
      """)

    assert {:ok, turtle} = TurtleCodec.encode(graph)
    assert {:ok, round_tripped} = TurtleCodec.decode(turtle)
    assert RDF.Graph.equal?(graph, round_tripped)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/riptide/rdf/turtle_codec_test.exs`
Expected: FAIL — `Riptide.RDF.TurtleCodec` module does not exist.

- [ ] **Step 3: Write the minimal implementation**

```elixir
# lib/riptide/rdf/turtle_codec.ex
defmodule Riptide.RDF.TurtleCodec do
  @moduledoc """
  Thin wrapper around RDF.Turtle so the rest of Riptide depends on this
  module's stable {:ok, _} | {:error, _} contract rather than the rdf
  library's own (bang vs non-bang) function-naming conventions directly.
  """

  @spec decode(String.t()) :: {:ok, RDF.Graph.t()} | {:error, term()}
  def decode(turtle_string) when is_binary(turtle_string) do
    case RDF.Turtle.read_string(turtle_string) do
      {:ok, graph} -> {:ok, graph}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec encode(RDF.Graph.t()) :: {:ok, String.t()} | {:error, term()}
  def encode(%RDF.Graph{} = graph) do
    case RDF.Turtle.write_string(graph) do
      {:ok, turtle} -> {:ok, turtle}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/riptide/rdf/turtle_codec_test.exs`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/riptide/rdf/turtle_codec.ex test/riptide/rdf/turtle_codec_test.exs
git commit -m "riptide: add Turtle codec wrapper"
```

---

### Task 11: `Riptide.RDF.Patch`

**Files:**
- Create: `lib/riptide/rdf/patch.ex`
- Test: `test/riptide/rdf/patch_test.exs`

**Interfaces:**
- Consumes: `RDF.Graph` (via Task 10's decoded graphs).
- Produces: `%Riptide.RDF.Patch{additions: [RDF.Triple.t()], removals: [RDF.Triple.t()]}`,
  `Riptide.RDF.Patch.apply(RDF.Graph.t(), Riptide.RDF.Patch.t()) :: RDF.Graph.t()`. Consumed by
  Task 12 (`ResourceController`'s `PATCH` handler).

- [ ] **Step 1: Write the failing test**

```elixir
# test/riptide/rdf/patch_test.exs
defmodule Riptide.RDF.PatchTest do
  use ExUnit.Case, async: true

  alias Riptide.RDF.Patch

  @alice RDF.iri("https://pod.example/alice")
  @name RDF.iri("https://pod.example/name")

  test "apply/2 adds triples from the additions list" do
    graph = RDF.Graph.new()
    patch = %Patch{additions: [{@alice, @name, RDF.literal("Alice")}], removals: []}

    result = Patch.apply(graph, patch)

    assert RDF.Graph.include?(result, {@alice, @name, RDF.literal("Alice")})
  end

  test "apply/2 removes triples from the removals list" do
    graph = RDF.Graph.new() |> RDF.Graph.add({@alice, @name, RDF.literal("Alice")})
    patch = %Patch{additions: [], removals: [{@alice, @name, RDF.literal("Alice")}]}

    result = Patch.apply(graph, patch)

    refute RDF.Graph.include?(result, {@alice, @name, RDF.literal("Alice")})
  end

  test "apply/2 applies removals before additions, so a replace-in-place works" do
    graph = RDF.Graph.new() |> RDF.Graph.add({@alice, @name, RDF.literal("Alice")})

    patch = %Patch{
      additions: [{@alice, @name, RDF.literal("Alicia")}],
      removals: [{@alice, @name, RDF.literal("Alice")}]
    }

    result = Patch.apply(graph, patch)

    refute RDF.Graph.include?(result, {@alice, @name, RDF.literal("Alice")})
    assert RDF.Graph.include?(result, {@alice, @name, RDF.literal("Alicia")})
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/riptide/rdf/patch_test.exs`
Expected: FAIL — `Riptide.RDF.Patch` module does not exist.

- [ ] **Step 3: Write the minimal implementation**

```elixir
# lib/riptide/rdf/patch.ex
defmodule Riptide.RDF.Patch do
  @moduledoc """
  An RDF Patch: an explicit add/remove delta against a graph, applied as
  removals-then-additions so a triple can be replaced in one patch.
  """

  @enforce_keys [:additions, :removals]
  defstruct [:additions, :removals]

  @type triple :: {RDF.IRI.t(), RDF.IRI.t(), RDF.Term.t()}
  @type t :: %__MODULE__{additions: [triple()], removals: [triple()]}

  @spec apply(RDF.Graph.t(), t()) :: RDF.Graph.t()
  def apply(%RDF.Graph{} = graph, %__MODULE__{additions: additions, removals: removals}) do
    graph
    |> RDF.Graph.delete(removals)
    |> RDF.Graph.add(additions)
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/riptide/rdf/patch_test.exs`
Expected: PASS (3 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/riptide/rdf/patch.ex test/riptide/rdf/patch_test.exs
git commit -m "riptide: add RDF Patch application"
```

---

### Task 12: `RiptideWeb.LDP.ResourceController` (CRUD)

**Files:**
- Create: `lib/riptide_web/ldp/resource_controller.ex`
- Modify: `lib/riptide_web/router.ex`
- Test: `test/riptide_web/ldp/resource_controller_test.exs`

**Interfaces:**
- Consumes: `Riptide.Stream.StreamSupervisor.get_or_start/1` (Task 9),
  `Riptide.Stream.StreamServer.append/2` and `get_since/2` (Task 8), `Riptide.Event.new/3`
  (Task 7), `Riptide.RDF.TurtleCodec.decode/1` and `encode/1` (Task 10),
  `Riptide.RDF.Patch.apply/2` (Task 11).
- Produces: `GET /resources/*path` (200 with current Turtle state, computed by folding all
  events for that resource's stream, or 404 if the stream has never been written to), `PUT
  /resources/*path` (replaces the resource's full state — appends a snapshot event), `DELETE
  /resources/*path` (appends an empty-graph snapshot event), `PATCH /resources/*path` (accepts
  a JSON body `{"additions": "<turtle>", "removals": "<turtle>"}`, appends a non-snapshot
  delta event). Resource identity = the full request URL, used directly as the `stream_id`.
  Consumed by Task 13 (container semantics build on the same controller).

- [ ] **Step 1: Write the failing test**

```elixir
# test/riptide_web/ldp/resource_controller_test.exs
defmodule RiptideWeb.LDP.ResourceControllerTest do
  use ExUnit.Case, async: true
  use Plug.Test

  @opts RiptideWeb.Endpoint.init([])

  defp unique_path, do: "/resources/test-#{System.unique_integer([:positive])}"

  test "GET on a resource that was never written to returns 404" do
    conn = :get |> conn(unique_path()) |> RiptideWeb.Endpoint.call(@opts)

    assert conn.status == 404
  end

  test "PUT creates a resource, and GET then returns its Turtle state" do
    path = unique_path()
    turtle = "<https://pod.example/x> <https://pod.example/y> \"z\" .\n"

    put_conn =
      :put
      |> conn(path, turtle)
      |> put_req_header("content-type", "text/turtle")
      |> RiptideWeb.Endpoint.call(@opts)

    assert put_conn.status == 201

    get_conn = :get |> conn(path) |> RiptideWeb.Endpoint.call(@opts)

    assert get_conn.status == 200
    assert get_conn.resp_body =~ "\"z\""
  end

  test "PATCH applies an additive delta on top of existing state" do
    path = unique_path()

    :put
    |> conn(path, "<https://pod.example/x> <https://pod.example/y> \"1\" .\n")
    |> put_req_header("content-type", "text/turtle")
    |> RiptideWeb.Endpoint.call(@opts)

    patch_body =
      Jason.encode!(%{
        "additions" => "<https://pod.example/x> <https://pod.example/y> \"2\" .\n",
        "removals" => ""
      })

    patch_conn =
      :patch
      |> conn(path, patch_body)
      |> put_req_header("content-type", "application/json")
      |> RiptideWeb.Endpoint.call(@opts)

    assert patch_conn.status == 200

    get_conn = :get |> conn(path) |> RiptideWeb.Endpoint.call(@opts)
    assert get_conn.resp_body =~ "\"1\""
    assert get_conn.resp_body =~ "\"2\""
  end

  test "DELETE removes the resource's visible state" do
    path = unique_path()

    :put
    |> conn(path, "<https://pod.example/x> <https://pod.example/y> \"z\" .\n")
    |> put_req_header("content-type", "text/turtle")
    |> RiptideWeb.Endpoint.call(@opts)

    delete_conn = :delete |> conn(path) |> RiptideWeb.Endpoint.call(@opts)
    assert delete_conn.status == 204

    get_conn = :get |> conn(path) |> RiptideWeb.Endpoint.call(@opts)
    assert get_conn.status == 404
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/riptide_web/ldp/resource_controller_test.exs`
Expected: FAIL — no `/resources/*path` route exists yet (404 on every request, including the
ones expecting 200/201/204, and the PUT-then-GET sequence has nothing to find).

- [ ] **Step 3: Write the minimal implementation**

```elixir
# lib/riptide_web/ldp/resource_controller.ex
defmodule RiptideWeb.LDP.ResourceController do
  use Phoenix.Controller

  alias Riptide.Event
  alias Riptide.RDF.{Patch, TurtleCodec}
  alias Riptide.Stream.{StreamServer, StreamSupervisor}

  def show(conn, %{"path" => path_segments}) do
    stream_id = stream_id_for(path_segments)

    case current_state(stream_id) do
      {:ok, graph} ->
        {:ok, turtle} = TurtleCodec.encode(graph)
        send_resp(conn, 200, turtle)

      :not_found ->
        send_resp(conn, 404, "")
    end
  end

  def replace(conn, %{"path" => path_segments}) do
    stream_id = stream_id_for(path_segments)
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {:ok, graph} = TurtleCodec.decode(body)

    StreamSupervisor.get_or_start(stream_id)
    StreamServer.append(stream_id, Event.new(stream_id, graph, true))

    send_resp(conn, 201, "")
  end

  def delete(conn, %{"path" => path_segments}) do
    stream_id = stream_id_for(path_segments)

    StreamSupervisor.get_or_start(stream_id)
    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new(), true))

    send_resp(conn, 204, "")
  end

  def patch(conn, %{"path" => path_segments}) do
    stream_id = stream_id_for(path_segments)
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    %{"additions" => additions_turtle, "removals" => removals_turtle} = Jason.decode!(body)

    {:ok, additions_graph} = TurtleCodec.decode(additions_turtle)
    {:ok, removals_graph} = TurtleCodec.decode(removals_turtle)

    patch = %Patch{
      additions: RDF.Graph.triples(additions_graph),
      removals: RDF.Graph.triples(removals_graph)
    }

    {:ok, current} = current_state(stream_id)
    delta_only_graph = Patch.apply(RDF.Graph.new(), patch)

    StreamSupervisor.get_or_start(stream_id)
    StreamServer.append(stream_id, Event.new(stream_id, delta_only_graph, false))

    _ = current
    send_resp(conn, 200, "")
  end

  defp stream_id_for(path_segments) do
    "https://riptide.example/resources/" <> Enum.join(path_segments, "/")
  end

  defp current_state(stream_id) do
    StreamSupervisor.get_or_start(stream_id)

    case StreamServer.get_since(stream_id, 0) do
      {:ok, []} ->
        :not_found

      {:ok, events} ->
        graph =
          Enum.reduce(events, RDF.Graph.new(), fn
            %Event{is_snapshot?: true, payload: payload}, _acc -> payload
            %Event{is_snapshot?: false, payload: delta}, acc -> RDF.Graph.add(acc, RDF.Graph.triples(delta))
          end)

        {:ok, graph}
    end
  end
end
```

```elixir
# lib/riptide_web/router.ex — add inside the existing :api scope from Task 6
scope "/" do
  pipe_through :api

  get "/health", RiptideWeb.HealthController, :show
  get "/resources/*path", RiptideWeb.LDP.ResourceController, :show
  put "/resources/*path", RiptideWeb.LDP.ResourceController, :replace
  delete "/resources/*path", RiptideWeb.LDP.ResourceController, :delete
  patch "/resources/*path", RiptideWeb.LDP.ResourceController, :patch
end
```

Note the `current_state/1` call to `StreamServer.get_since(stream_id, 0)` relies on Task 8's
`get_since/2` gap logic: since `0` is always `>= oldest - 1` for any positive `oldest`, this
never triggers a gap — it always means "everything," which is exactly the "fold from the
start" semantics `current_state/1` needs.

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/riptide_web/ldp/resource_controller_test.exs`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/riptide_web/ldp/resource_controller.ex lib/riptide_web/router.ex \
  test/riptide_web/ldp/resource_controller_test.exs
git commit -m "riptide: add LDP resource CRUD backed by the event log"
```

---

### Task 13: Container semantics (`ldp:contains`)

**Files:**
- Modify: `lib/riptide_web/ldp/resource_controller.ex`
- Modify: `lib/riptide_web/router.ex`
- Test: `test/riptide_web/ldp/resource_controller_test.exs` (extend)

**Interfaces:**
- Consumes: everything from Task 12.
- Produces: `POST /resources/*path` creates a new child resource under the container at `path`
  (identified by a server-assigned child ID), returns `201` with a `Location` header pointing at
  the new child, and appends an `ldp:contains` triple to the container's own stream.

- [ ] **Step 1: Write the failing test**

```elixir
# Append to test/riptide_web/ldp/resource_controller_test.exs

test "POST to a container creates a child resource and records ldp:contains" do
  container_path = unique_path()
  child_turtle = "<https://pod.example/a> <https://pod.example/b> \"c\" .\n"

  post_conn =
    :post
    |> conn(container_path, child_turtle)
    |> put_req_header("content-type", "text/turtle")
    |> RiptideWeb.Endpoint.call(@opts)

  assert post_conn.status == 201
  [location] = Plug.Conn.get_resp_header(post_conn, "location")
  assert location =~ container_path

  child_get_conn = :get |> conn(location) |> RiptideWeb.Endpoint.call(@opts)
  assert child_get_conn.status == 200
  assert child_get_conn.resp_body =~ "\"c\""

  container_get_conn = :get |> conn(container_path) |> RiptideWeb.Endpoint.call(@opts)
  assert container_get_conn.resp_body =~ "ldp#contains"
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/riptide_web/ldp/resource_controller_test.exs`
Expected: FAIL — no `POST /resources/*path` route exists yet.

- [ ] **Step 3: Write the minimal implementation**

```elixir
# lib/riptide_web/ldp/resource_controller.ex — add this function

@ldp_contains RDF.iri("http://www.w3.org/ns/ldp#contains")

def create_child(conn, %{"path" => path_segments}) do
  container_stream_id = stream_id_for(path_segments)
  {:ok, body, conn} = Plug.Conn.read_body(conn)
  {:ok, child_graph} = TurtleCodec.decode(body)

  child_id = Ecto.UUID.generate()
  child_stream_id = container_stream_id <> "/" <> child_id

  StreamSupervisor.get_or_start(child_stream_id)
  StreamServer.append(child_stream_id, Event.new(child_stream_id, child_graph, true))

  containment_triple = {RDF.iri(container_stream_id), @ldp_contains, RDF.iri(child_stream_id)}
  containment_graph = RDF.Graph.new() |> RDF.Graph.add(containment_triple)

  StreamSupervisor.get_or_start(container_stream_id)
  StreamServer.append(container_stream_id, Event.new(container_stream_id, containment_graph, false))

  location = "/resources/" <> Enum.join(path_segments, "/") <> "/" <> child_id

  conn
  |> put_resp_header("location", location)
  |> send_resp(201, "")
end
```

`Ecto.UUID` ships as part of the `ecto` package, which this project deliberately excluded
(`--no-ecto`). Add the standalone `uniq` dependency instead for UUID generation:

```elixir
# mix.exs — add to deps()
{:uniq, "~> 0.6"}
```

And use `Uniq.UUID.uuid4()` in place of `Ecto.UUID.generate()` above.

```elixir
# lib/riptide_web/router.ex — add inside the existing :api scope
post "/resources/*path", RiptideWeb.LDP.ResourceController, :create_child
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix deps.get && mix test test/riptide_web/ldp/resource_controller_test.exs`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add mix.exs mix.lock lib/riptide_web/ldp/resource_controller.ex lib/riptide_web/router.ex \
  test/riptide_web/ldp/resource_controller_test.exs
git commit -m "riptide: add LDP container semantics (POST + ldp:contains)"
```

---

### Task 14: SSE endpoint (`RiptideWeb.Realtime.SseController`)

**Files:**
- Create: `lib/riptide_web/realtime/sse_controller.ex`
- Modify: `lib/riptide_web/router.ex`
- Test: `test/riptide_web/realtime/sse_controller_test.exs`

**Interfaces:**
- Consumes: `Riptide.Stream.StreamSupervisor.get_or_start/1`, `Riptide.Stream.StreamServer`
  (register for push notifications — see implementation below, which adds a `subscribe/1` /
  broadcast mechanism to `StreamServer`), `Riptide.Event`, `Riptide.RDF.TurtleCodec.encode/1`.
- Produces: `GET /resources/*path/subscribe` — an SSE stream. Honors an incoming `Last-Event-ID`
  request header as the StreamLD cursor; each new event is written as one SSE frame with `id:
  <sequence>` and `data: <turtle payload>`.

**Note on `StreamServer` extension needed by this task:** `StreamServer` (Task 8) has no way yet
to notify a live subscriber of new appends — `get_since/2` only serves already-appended events.
Add a minimal pub/sub hook using `Phoenix.PubSub` (already a transitive dependency of `phoenix`):
on every successful `append`, `StreamServer` broadcasts `{:new_event, event}` on the topic
`"stream:" <> stream_id` via `Phoenix.PubSub.broadcast(Riptide.PubSub, topic, message)`. Add
`{Phoenix.PubSub, name: Riptide.PubSub}` to `Riptide.Application`'s supervision tree.

- [ ] **Step 1: Write the failing test**

```elixir
# test/riptide_web/realtime/sse_controller_test.exs
defmodule RiptideWeb.Realtime.SseControllerTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias Riptide.Event
  alias Riptide.Stream.{StreamServer, StreamSupervisor}

  @opts RiptideWeb.Endpoint.init([])

  defp unique_stream_id, do: "sse-test-#{System.unique_integer([:positive])}"

  test "subscribing with no Last-Event-ID and then appending pushes one SSE frame" do
    stream_id = unique_stream_id()
    StreamSupervisor.get_or_start(stream_id)

    task =
      Task.async(fn ->
        :get
        |> conn("/streams/#{URI.encode_www_form(stream_id)}/subscribe")
        |> RiptideWeb.Endpoint.call(@opts)
      end)

    Process.sleep(50)
    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))

    conn = Task.await(task, 1_000)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    assert conn.resp_body =~ "id: 1\n"
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/riptide_web/realtime/sse_controller_test.exs`
Expected: FAIL — no `/streams/:stream_id/subscribe` route exists yet.

- [ ] **Step 3: Write the minimal implementation**

```elixir
# lib/riptide/stream/stream_server.ex — modify handle_call({:append, ...}, ...)

@impl true
def handle_call({:append, event}, _from, state) do
  stamped = Event.with_sequence(event, state.next_sequence)
  new_state = %{state | next_sequence: state.next_sequence + 1, events: state.events ++ [stamped]}

  Phoenix.PubSub.broadcast(Riptide.PubSub, "stream:" <> state.stream_id, {:new_event, stamped})

  {:reply, stamped, new_state}
end
```

```elixir
# lib/riptide/application.ex — add {Phoenix.PubSub, name: Riptide.PubSub} to children,
# before RiptideWeb.Endpoint:

children = [
  {Registry, keys: :unique, name: Riptide.Stream.Registry},
  Riptide.Stream.StreamSupervisor,
  {Phoenix.PubSub, name: Riptide.PubSub},
  RiptideWeb.Endpoint
]
```

```elixir
# lib/riptide_web/realtime/sse_controller.ex
defmodule RiptideWeb.Realtime.SseController do
  use Phoenix.Controller

  alias Riptide.RDF.TurtleCodec
  alias Riptide.Stream.{StreamServer, StreamSupervisor}

  def subscribe(conn, %{"stream_id" => stream_id}) do
    StreamSupervisor.get_or_start(stream_id)
    Phoenix.PubSub.subscribe(Riptide.PubSub, "stream:" <> stream_id)

    cursor = last_event_id(conn)

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    conn =
      case StreamServer.get_since(stream_id, cursor) do
        {:ok, backlog} -> Enum.reduce(backlog, conn, &write_event(&2, &1))
        {:gap, _oldest} -> conn
      end

    loop(conn)
  end

  defp loop(conn) do
    receive do
      {:new_event, event} ->
        conn = write_event(conn, event)
        loop(conn)
    after
      1_000 -> conn
    end
  end

  defp write_event(conn, event) do
    {:ok, turtle} = TurtleCodec.encode(event.payload)
    frame = "id: #{event.sequence}\ndata: #{String.replace(turtle, "\n", "\ndata: ")}\n\n"
    {:ok, conn} = Plug.Conn.chunk(conn, frame)
    conn
  end

  defp last_event_id(conn) do
    case Plug.Conn.get_req_header(conn, "last-event-id") do
      [id] -> String.to_integer(id)
      [] -> nil
    end
  end
end
```

```elixir
# lib/riptide_web/router.ex — add inside the existing :api scope
get "/streams/:stream_id/subscribe", RiptideWeb.Realtime.SseController, :subscribe
```

The test's `Task.async` + `Process.sleep(50)` + `after 1_000 -> conn` combination is
intentionally simple for a first-phase reference implementation: it gives the controller time
to subscribe before the test appends, and the controller's own 1-second idle timeout ensures
`Task.await(task, 1_000)` in the test doesn't hang forever waiting on a connection that never
closes. A production-grade version would negotiate a close condition explicitly rather than
timing out — noted as a known simplification, not silently hidden.

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/riptide_web/realtime/sse_controller_test.exs`
Expected: PASS

- [ ] **Step 5: Run the full test suite to confirm no regressions, then commit**

Run: `mix test`
Expected: PASS (all tests, including Tasks 1-13's)

```bash
git add lib/riptide/stream/stream_server.ex lib/riptide/application.ex \
  lib/riptide_web/realtime/sse_controller.ex lib/riptide_web/router.ex \
  test/riptide_web/realtime/sse_controller_test.exs
git commit -m "riptide: add SSE subscription endpoint with Last-Event-ID support"
```

---

### Task 15: Gap detection end-to-end (retention trim + SSE 409 response)

**Files:**
- Modify: `lib/riptide/stream/stream_server.ex`
- Modify: `lib/riptide_web/realtime/sse_controller.ex`
- Test: `test/riptide/stream/stream_server_test.exs` (extend)
- Test: `test/riptide_web/realtime/sse_controller_test.exs` (extend)

**Interfaces:**
- Consumes: `Riptide.Stream.StreamServer`'s existing `{:gap, oldest}` return, already defined in
  Task 8 but never exercised because nothing trims retained events yet.
- Produces: a configurable per-stream retention limit (`Riptide.Stream.StreamServer.start_link/2`
  gains an options list with a `:retention` key, default `:infinity`), and a real gap: once a
  stream exceeds its retention count, `get_since/2` with an old-enough cursor returns `{:gap,
  oldest}` for real (Task 8's logic already handles this correctly once `state.events` is
  actually trimmed — this task is about making trimming happen, not changing the gap-detection
  logic itself). The SSE controller responds `409` with a `streamld:GapSignal`-shaped JSON body
  when it receives `{:gap, oldest}`.

- [ ] **Step 1: Write the failing tests**

```elixir
# Append to test/riptide/stream/stream_server_test.exs

test "a stream started with a retention limit trims old events", %{stream_id: _unused} do
  stream_id = "stream-retention-#{System.unique_integer([:positive])}"
  start_supervised!({StreamServer, {stream_id, retention: 2}}, id: :retained_stream)

  StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))
  StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))
  StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))

  assert {:gap, 2} = StreamServer.get_since(stream_id, 0)
  assert {:ok, [%{sequence: 3}]} = StreamServer.get_since(stream_id, 2)
end
```

```elixir
# Append to test/riptide_web/realtime/sse_controller_test.exs

test "subscribing with a cursor older than the retention window returns 409 with a gap signal" do
  stream_id = "sse-gap-test-#{System.unique_integer([:positive])}"
  {:ok, _pid} = Riptide.Stream.StreamServer.start_link({stream_id, retention: 1})

  Riptide.Stream.StreamServer.append(stream_id, Riptide.Event.new(stream_id, RDF.Graph.new()))
  Riptide.Stream.StreamServer.append(stream_id, Riptide.Event.new(stream_id, RDF.Graph.new()))

  conn =
    :get
    |> conn("/streams/#{URI.encode_www_form(stream_id)}/subscribe")
    |> put_req_header("last-event-id", "0")
    |> RiptideWeb.Endpoint.call(@opts)

  assert conn.status == 409
  assert Jason.decode!(conn.resp_body) == %{"oldestAvailable" => 2}
end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mix test test/riptide/stream/stream_server_test.exs test/riptide_web/realtime/sse_controller_test.exs`
Expected: FAIL — `StreamServer.start_link/1` doesn't accept a `{stream_id, opts}` tuple yet, so
retention is never configured and no gap ever actually fires (events are never trimmed).

- [ ] **Step 3: Write the minimal implementation**

```elixir
# lib/riptide/stream/stream_server.ex — replace start_link/1, init/1, and the :append clause

def start_link({stream_id, opts}) do
  GenServer.start_link(__MODULE__, {stream_id, opts}, name: via(stream_id))
end

def start_link(stream_id) when is_binary(stream_id) do
  start_link({stream_id, []})
end

@impl true
def init({stream_id, opts}) do
  retention = Keyword.get(opts, :retention, :infinity)
  {:ok, %{stream_id: stream_id, next_sequence: 1, events: [], retention: retention}}
end

@impl true
def handle_call({:append, event}, _from, state) do
  stamped = Event.with_sequence(event, state.next_sequence)
  events = trim(state.events ++ [stamped], state.retention)
  new_state = %{state | next_sequence: state.next_sequence + 1, events: events}

  Phoenix.PubSub.broadcast(Riptide.PubSub, "stream:" <> state.stream_id, {:new_event, stamped})

  {:reply, stamped, new_state}
end

defp trim(events, :infinity), do: events

defp trim(events, retention) when is_integer(retention) do
  count = length(events)
  if count > retention, do: Enum.drop(events, count - retention), else: events
end
```

- [ ] **Step 4: Update the SSE controller to translate `{:gap, oldest}` into a 409 response**

```elixir
# lib/riptide_web/realtime/sse_controller.ex — replace the case in subscribe/2

def subscribe(conn, %{"stream_id" => stream_id}) do
  StreamSupervisor.get_or_start(stream_id)
  Phoenix.PubSub.subscribe(Riptide.PubSub, "stream:" <> stream_id)

  cursor = last_event_id(conn)

  case StreamServer.get_since(stream_id, cursor) do
    {:gap, oldest} ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(409, Jason.encode!(%{"oldestAvailable" => oldest}))

    {:ok, backlog} ->
      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> send_chunked(200)

      conn = Enum.reduce(backlog, conn, &write_event(&2, &1))
      loop(conn)
  end
end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `mix test test/riptide/stream/stream_server_test.exs test/riptide_web/realtime/sse_controller_test.exs`
Expected: PASS

- [ ] **Step 6: Run the full test suite to confirm no regressions, then commit**

Run: `mix test`
Expected: PASS

```bash
git add lib/riptide/stream/stream_server.ex lib/riptide_web/realtime/sse_controller.ex \
  test/riptide/stream/stream_server_test.exs test/riptide_web/realtime/sse_controller_test.exs
git commit -m "riptide: implement retention trimming and end-to-end gap signaling"
```

---

### Task 16: WebSocket replication channel (`RiptideWeb.Realtime.ReplicationChannel`)

**Files:**
- Create: `lib/riptide_web/realtime/replication_channel.ex`
- Create: `lib/riptide_web/realtime/socket.ex`
- Modify: `lib/riptide_web/endpoint.ex` (mount the socket)
- Test: `test/riptide_web/realtime/replication_channel_test.exs`

**Interfaces:**
- Consumes: `Riptide.Stream.StreamServer.get_since/2`, `Riptide.Stream.StreamSupervisor
  .get_or_start/1`, the `{:new_event, event}` PubSub broadcast added in Task 14.
- Produces: a Phoenix Channel topic `"replication:" <> stream_id`, joined with `%{"after" =>
  cursor}` payload. On join, replies with `{:ok, %{"backlog" => [...]}}` (already-buffered
  events past the cursor) or `{:error, %{"gap" => oldest}}`. After join, pushes one
  `"replication_frame"` message per new append, each shaped like the `streamld:ReplicationFrame`
  SHACL shape from Task 2 (`cursor` and `event` keys).

- [ ] **Step 1: Write the failing test**

```elixir
# test/riptide_web/realtime/replication_channel_test.exs
defmodule RiptideWeb.Realtime.ReplicationChannelTest do
  use ExUnit.Case, async: true
  import Phoenix.ChannelTest

  alias Riptide.Event
  alias Riptide.Stream.{StreamServer, StreamSupervisor}
  alias RiptideWeb.Realtime.{ReplicationChannel, Socket}

  @endpoint RiptideWeb.Endpoint

  defp unique_stream_id, do: "ws-test-#{System.unique_integer([:positive])}"

  test "joining with after: 0 receives no backlog on an empty stream" do
    stream_id = unique_stream_id()
    StreamSupervisor.get_or_start(stream_id)

    {:ok, socket} = connect(Socket, %{})

    {:ok, reply, _socket} = subscribe_and_join(socket, ReplicationChannel, "replication:" <> stream_id, %{"after" => 0})

    assert reply == %{"backlog" => []}
  end

  test "joining with after: 0 on a non-empty stream replies with the existing backlog" do
    stream_id = unique_stream_id()
    StreamSupervisor.get_or_start(stream_id)
    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))

    {:ok, socket} = connect(Socket, %{})
    {:ok, reply, _socket} =
      subscribe_and_join(socket, ReplicationChannel, "replication:" <> stream_id, %{"after" => 0})

    assert %{"backlog" => [%{"cursor" => 1}]} = reply
  end

  test "joining with a cursor older than the retention window is rejected with a gap" do
    stream_id = unique_stream_id()
    {:ok, _pid} = StreamServer.start_link({stream_id, retention: 1})
    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))
    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))

    {:ok, socket} = connect(Socket, %{})

    assert {:error, %{"gap" => 2}} =
             subscribe_and_join(socket, ReplicationChannel, "replication:" <> stream_id, %{"after" => 0})
  end

  test "new appends after joining are pushed as replication_frame messages" do
    stream_id = unique_stream_id()
    StreamSupervisor.get_or_start(stream_id)

    {:ok, socket} = connect(Socket, %{})
    {:ok, _reply, _socket} =
      subscribe_and_join(socket, ReplicationChannel, "replication:" <> stream_id, %{"after" => 0})

    StreamServer.append(stream_id, Event.new(stream_id, RDF.Graph.new()))

    assert_push "replication_frame", %{"cursor" => 1}
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/riptide_web/realtime/replication_channel_test.exs`
Expected: FAIL — `RiptideWeb.Realtime.Socket` and `RiptideWeb.Realtime.ReplicationChannel` do
not exist.

- [ ] **Step 3: Write the minimal implementation**

```elixir
# lib/riptide_web/realtime/socket.ex
defmodule RiptideWeb.Realtime.Socket do
  use Phoenix.Socket

  channel "replication:*", RiptideWeb.Realtime.ReplicationChannel

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
```

```elixir
# lib/riptide_web/realtime/replication_channel.ex
defmodule RiptideWeb.Realtime.ReplicationChannel do
  use Phoenix.Channel

  alias Riptide.Event
  alias Riptide.RDF.TurtleCodec
  alias Riptide.Stream.{StreamServer, StreamSupervisor}

  @impl true
  def join("replication:" <> stream_id, %{"after" => cursor}, socket) do
    StreamSupervisor.get_or_start(stream_id)
    Phoenix.PubSub.subscribe(Riptide.PubSub, "stream:" <> stream_id)

    case StreamServer.get_since(stream_id, cursor) do
      {:gap, oldest} ->
        {:error, %{"gap" => oldest}}

      {:ok, events} ->
        socket = assign(socket, :stream_id, stream_id)
        {:ok, %{"backlog" => Enum.map(events, &frame/1)}, socket}
    end
  end

  @impl true
  def handle_info({:new_event, %Event{} = event}, socket) do
    push(socket, "replication_frame", frame(event))
    {:noreply, socket}
  end

  defp frame(%Event{} = event) do
    {:ok, turtle} = TurtleCodec.encode(event.payload)
    %{"cursor" => event.sequence, "event" => %{"sequence" => event.sequence, "payload" => turtle}}
  end
end
```

```elixir
# lib/riptide_web/endpoint.ex — add above `plug RiptideWeb.Router`
socket "/replication", RiptideWeb.Realtime.Socket, websocket: true
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/riptide_web/realtime/replication_channel_test.exs`
Expected: PASS (4 tests)

- [ ] **Step 5: Run the full test suite to confirm no regressions, then commit**

Run: `mix test`
Expected: PASS (every test written across all 16 tasks)

```bash
git add lib/riptide_web/realtime/socket.ex lib/riptide_web/realtime/replication_channel.ex \
  lib/riptide_web/endpoint.ex test/riptide_web/realtime/replication_channel_test.exs
git commit -m "riptide: add WebSocket replication channel"
```

---

### Task 17: Author the transport-binding and subscription specs

**Files:**
- Create: `spec/streamld/binding-sse.bs`
- Create: `spec/streamld/binding-websocket.bs`
- Create: `spec/streamld/subscription.bs`

**Interfaces:**
- Consumes: `spec/streamld/core.bs` (Task 5), and the now-proven behavior of Tasks 14-16's
  Elixir implementation (these documents describe what Riptide actually does, closing the loop
  between implementation and spec per the design doc's process — see design doc §3.6/§4.5).
- Produces: three more built Bikeshed documents, completing the CloudEvents-style spec
  structure.

- [ ] **Step 1: Write `binding-sse.bs`**

```html
<pre class='metadata'>
Title: StreamLD SSE Binding
Shortname: streamld-sse
Level: 1
Status: w3c/CG-DRAFT
Group: openfaster
URL: https://openfaster.org/streamld/binding-sse.html
Editor: OpenFASTER Editors
Abstract: Defines how StreamLD's cursor-based subscription model (see [[streamld-core]]) is carried over Server-Sent Events, for server-to-client delivery.
</pre>

# Overview # {#overview}

A client subscribes to a stream by opening an SSE connection to that stream's
subscription endpoint. The connection MUST be served over HTTP/2 or later, to
avoid the six-connections-per-origin limit HTTP/1.1 imposes on `EventSource`.

# Resumption # {#resumption}

The StreamLD cursor (see [[streamld-core#cursor]]) is carried directly as the
SSE `id` field of each event. A reconnecting client's browser automatically
resends the last-seen `id` as the `Last-Event-ID` request header; a
conformant server MUST treat an incoming `Last-Event-ID` header as the
`streamld:after` value of an implicit subscription request.

# Gap responses # {#gap-responses}

If the requested cursor cannot be satisfied (see
[[streamld-core#gap-handling]]), the server MUST respond with HTTP status 409
and a JSON body matching the `streamld:GapSignal` shape, and MUST NOT begin an
`text/event-stream` response in that case.
```

- [ ] **Step 2: Write `binding-websocket.bs`**

```html
<pre class='metadata'>
Title: StreamLD WebSocket Replication Binding
Shortname: streamld-websocket
Level: 1
Status: w3c/CG-DRAFT
Group: openfaster
URL: https://openfaster.org/streamld/binding-websocket.html
Editor: OpenFASTER Editors
Abstract: Defines StreamLD's server-to-server replication binding over WebSockets — the transport a downstream server uses to mirror an upstream stream in full, in order, with explicit resumption.
</pre>

# Overview # {#overview}

Unlike the SSE binding ([[streamld-sse]]), which serves a single browser
client, the WebSocket replication binding is intended for one server
mirroring another server's stream in full. There is no browser-platform
reconnection help available on this transport, so resumption is handled
entirely in-protocol.

# Join and backlog # {#join}

A replicating server opens a WebSocket connection and sends a join request
carrying a `streamld:SubscriptionRequest` (see [[streamld-core#envelope]]). The
upstream server responds with either:

* every already-buffered `streamld:ReplicationFrame` with `streamld:cursor`
  greater than the requested `streamld:after` value, in ascending cursor
  order, or
* a `streamld:GapSignal`, per the same rule as [[streamld-core#gap-handling]],
  if the requested cursor is not resolvable.

# Live frames # {#live-frames}

After a successful join, the upstream server pushes one
`streamld:ReplicationFrame` per subsequent append, in cursor order. A
replicating server MUST persist the highest cursor it has durably stored, so
that a reconnect after a network interruption can resume from that persisted
cursor rather than the beginning of the stream.
```

- [ ] **Step 3: Write `subscription.bs`**

```html
<pre class='metadata'>
Title: StreamLD Subscription and Discovery
Shortname: streamld-subscription
Level: 1
Status: w3c/CG-DRAFT
Group: openfaster
URL: https://openfaster.org/streamld/subscription.html
Editor: OpenFASTER Editors
Abstract: Defines how a client discovers a stream's subscription endpoint(s), independent of which transport binding ([[streamld-sse]] or [[streamld-websocket]]) it then uses.
</pre>

# Overview # {#overview}

This document separates *discovering* a stream's subscribable endpoint from
*subscribing* to it over a specific transport — the same separation
[[streamld-sse]] and [[streamld-websocket]] rely on, and the same one
AsyncAPI draws between its Channel and Operation objects.

# Discovery # {#discovery}

A StreamLD resource MUST advertise its subscription endpoint(s) via one `Link`
response header per supported transport binding, using a `rel` value scoped
to that binding (e.g. `rel="https://openfaster.org/streamld#sse"` or
`rel="https://openfaster.org/streamld#websocket-replication"`). A client MUST
NOT assume a fixed URL pattern (such as appending `/subscribe`) — the `Link`
header is the only conformant discovery mechanism.
```

- [ ] **Step 4: Build all three and verify they compile cleanly**

Run:
```bash
cd spec/streamld
bikeshed --allow-nonlocal-files --die-on=link-error spec binding-sse.bs binding-sse.html
bikeshed --allow-nonlocal-files --die-on=link-error spec binding-websocket.bs binding-websocket.html
bikeshed --allow-nonlocal-files --die-on=link-error spec subscription.bs subscription.html
```
Expected: all three exit 0 and produce non-empty HTML files.

- [ ] **Step 5: Commit**

```bash
cd spec
git add streamld/binding-sse.bs streamld/binding-sse.html streamld/binding-websocket.bs \
  streamld/binding-websocket.html streamld/subscription.bs streamld/subscription.html
git commit -m "streamld: author SSE, WebSocket replication, and subscription/discovery specs"
```

---

## Self-Review

**Spec coverage:** every numbered section of the design doc has a task —
§4.1/4.2 (core data model, cursor) → Tasks 1, 5, 8, 15; §4.3 (transports) → Tasks 14, 16, 17;
§4.4 (SHACL source of truth) → Tasks 1-4; §4.5 (spec doc structure) → Tasks 5, 17; §5 (Riptide
components/data flow/error handling) → Tasks 6-16; §6 (first-phase scope) → respected throughout
(no auth/WAC/MQTT/multi-tenancy task exists). §7's open items (which Elixir SHACL-tooling
approach, the WebSocket wire-format's exact framing, retention semantics) are intentionally
**not** resolved by this plan beyond what's needed for a working first-phase slice — Task 15's
retention is a simple count-based trim, not a policy language, and Task 16 hand-writes Elixir
structs (§4.4's option (b)) rather than building a `shacl2code` Elixir backend (option (a)),
which is the pragmatic choice for a first reference implementation and is stated as such rather
than silently picked.

**Placeholder scan:** no TBD/TODO markers; every code step contains complete, runnable code;
every test asserts concrete expected values, not "add appropriate assertions."

**Type consistency:** `Riptide.Event`'s field names (`sequence`, `stream_id`, `is_snapshot?`,
`payload`) are introduced in Task 7 and used identically in Tasks 8, 9, 12, 13, 14, 15, 16 — no
drift. `StreamServer.get_since/2`'s two-tuple return shapes (`{:ok, [Event.t()]}` and `{:gap,
pos_integer() | nil}`) are introduced in Task 8 and pattern-matched identically in Tasks 12, 14,
15, 16.
