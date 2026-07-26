-- Authoritative catalog DDL. Embedded and executed by Agda2Lean.Catalog.
-- Runtime PRAGMAs are applied separately before migration.

CREATE TABLE IF NOT EXISTS catalog_meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS ir_objects (
    object_hash BLOB PRIMARY KEY,
    object_kind TEXT NOT NULL CHECK (object_kind IN ('module')),
    codec_version INTEGER NOT NULL CHECK (codec_version > 0),
    cbor BLOB NOT NULL,
    byte_length INTEGER NOT NULL CHECK (byte_length = length(cbor)),
    created_at TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS module_heads (
    module_name TEXT PRIMARY KEY,
    object_hash BLOB NOT NULL REFERENCES ir_objects(object_hash),
    declaration_count INTEGER NOT NULL CHECK (declaration_count >= 0),
    term_count INTEGER NOT NULL CHECK (term_count >= 0),
    updated_at TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS declarations (
    -- Canonical names are globally unique and validation requires each name
    -- to be nested under its owning module's canonical namespace.
    declaration_name TEXT PRIMARY KEY,
    module_name TEXT NOT NULL REFERENCES module_heads(module_name)
        ON DELETE CASCADE,
    role TEXT NOT NULL CHECK (role IN (
        'computational-data',
        'computational-function',
        'computational-witness',
        'logical-proposition',
        'theorem',
        'axiom',
        'certificate',
        'adapter'
    )),
    mapping_mode TEXT NOT NULL CHECK (mapping_mode IN (
        'exact',
        'encoded',
        'reconstruct',
        'quarantined',
        'unsupported'
    )),
    type_term_id INTEGER NOT NULL,
    body_term_id INTEGER,
    source_file TEXT NOT NULL,
    source_start_line INTEGER NOT NULL CHECK (source_start_line > 0),
    source_end_line INTEGER NOT NULL
        CHECK (source_end_line >= source_start_line)
) STRICT;

CREATE INDEX IF NOT EXISTS declarations_by_module
    ON declarations(module_name);

CREATE INDEX IF NOT EXISTS declarations_by_status
    ON declarations(role, mapping_mode);

CREATE TABLE IF NOT EXISTS direct_dependencies (
    declaration_name TEXT NOT NULL REFERENCES declarations(declaration_name)
        ON DELETE CASCADE,
    dependency_name TEXT NOT NULL,
    PRIMARY KEY (declaration_name, dependency_name)
) WITHOUT ROWID, STRICT;

CREATE INDEX IF NOT EXISTS dependencies_by_target
    ON direct_dependencies(dependency_name);

CREATE TABLE IF NOT EXISTS module_imports (
    module_name TEXT NOT NULL REFERENCES module_heads(module_name)
        ON DELETE CASCADE,
    imported_module_name TEXT NOT NULL,
    PRIMARY KEY (module_name, imported_module_name)
) WITHOUT ROWID, STRICT;
