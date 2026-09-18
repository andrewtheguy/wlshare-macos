//! `include/wlshare_client.h` is hand-written, and the app compiles against it
//! rather than against the Rust. A type that differs between the two — a
//! `uint16_t` where the Rust says `u32`, a field in the wrong place — links
//! cleanly and corrupts memory at run time, and no amount of testing either
//! side alone would find it.
//!
//! So: read both, and compare. The header is parsed as C and `src/ffi.rs` as
//! Rust, by two parsers that know nothing about each other beyond the table
//! mapping one language's spelling of a type to the other's.

use std::collections::BTreeMap;

/// How a Rust type in the FFI is spelled in C. Anything not in here is a type
/// the ABI has not been thought about for, and the test says so rather than
/// guessing.
const TYPES: &[(&str, &str)] = &[
    ("()", "void"),
    ("bool", "bool"),
    ("f64", "double"),
    ("i32", "int32_t"),
    ("u8", "uint8_t"),
    ("u16", "uint16_t"),
    ("u32", "uint32_t"),
    ("u64", "uint64_t"),
    ("usize", "size_t"),
    ("*const c_char", "const char *"),
    ("*mut c_char", "char *"),
    ("*const u8", "const uint8_t *"),
    ("*mut u8", "uint8_t *"),
    ("*mut c_void", "void *"),
    ("*const Client", "const WlshareClient *"),
    ("*mut Client", "WlshareClient *"),
    ("*mut WlshareStatus", "WlshareStatus *"),
    ("Option<WlshareWakeFn>", "WlshareWakeFn"),
    ("WlshareFrameFn", "WlshareFrameFn"),
    ("WlshareCursorFn", "WlshareCursorFn"),
    ("WlshareClipboardFn", "WlshareClipboardFn"),
];

/// A declaration, in the one spelling both parsers produce: the C type with
/// every space taken out, so that `const char *` and `const char*` are one
/// thing.
type Fields = Vec<(String, String)>;

#[derive(Debug, PartialEq, Eq)]
struct Function {
    returns: String,
    params: Fields,
}

fn c_type(rust: &str) -> String {
    let rust = rust.trim();
    let c = TYPES
        .iter()
        .find(|(from, _)| *from == rust)
        .unwrap_or_else(|| panic!("the FFI uses the Rust type `{rust}`, which this test has no C spelling for — add it to TYPES"))
        .1;
    squash(c)
}

fn squash(c_type: &str) -> String {
    c_type.chars().filter(|c| !c.is_whitespace()).collect()
}

// ── The Rust half ────────────────────────────────────────────────────────────

fn rust_source() -> String {
    let source = include_str!("../src/ffi.rs");
    // Comments carry commas, braces and the word `fn`; none of them is code.
    source
        .lines()
        .map(|line| match line.find("//") {
            Some(at) => &line[..at],
            None => line,
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn rust_functions(source: &str) -> BTreeMap<String, Function> {
    let mut functions = BTreeMap::new();
    let mut rest = source;
    while let Some(at) = rest.find("extern \"C\" fn ") {
        rest = &rest[at + "extern \"C\" fn ".len()..];
        let open = rest.find('(').expect("a function has a parameter list");
        let name = rest[..open].trim().to_owned();
        let close = rest.find(')').expect("a parameter list ends");
        let params = fields(&rest[open + 1..close], |param| {
            let (name, ty) = param.split_once(':').expect("a Rust parameter is `name: type`");
            (name.trim().to_owned(), c_type(ty))
        });
        rest = &rest[close + 1..];
        let body = rest.find('{').expect("a function has a body");
        let returns = match rest[..body].trim().strip_prefix("->") {
            Some(ty) => c_type(ty),
            None => c_type("()"),
        };
        functions.insert(name, Function { returns, params });
    }
    functions
}

fn rust_structs(source: &str) -> BTreeMap<String, Fields> {
    let mut structs = BTreeMap::new();
    let mut rest = source;
    while let Some(at) = rest.find("pub struct Wlshare") {
        rest = &rest[at + "pub struct ".len()..];
        let open = rest.find('{').expect("a struct has a body");
        let name = rest[..open].trim().to_owned();
        let close = rest.find('}').expect("a struct body ends");
        let members = fields(&rest[open + 1..close], |member| {
            let member = member.trim().strip_prefix("pub ").expect("an FFI struct's fields are public");
            let (name, ty) = member.split_once(':').expect("a Rust field is `name: type`");
            (name.trim().to_owned(), c_type(ty))
        });
        structs.insert(name, members);
        rest = &rest[close + 1..];
    }
    structs
}

fn fields(list: &str, parse: impl Fn(&str) -> (String, String)) -> Fields {
    list.split(',').map(str::trim).filter(|part| !part.is_empty()).map(parse).collect()
}

// ── The C half ───────────────────────────────────────────────────────────────

fn c_source() -> String {
    let mut out = String::new();
    let header = include_str!("../include/wlshare_client.h");
    let mut rest = header;
    while let Some(at) = rest.find("/*") {
        out.push_str(&rest[..at]);
        rest = &rest[at + 2..];
        let end = rest.find("*/").expect("a comment ends");
        rest = &rest[end + 2..];
    }
    out.push_str(rest);
    // The preprocessor lines and the `extern "C"` guard declare nothing this
    // test compares. The struct typedefs do, and the caller takes those out
    // before looking for functions.
    out.lines()
        .filter(|line| {
            let line = line.trim();
            !line.starts_with('#') && line != "extern \"C\" {" && line != "}"
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// The `typedef struct { ... } Name;` blocks, and what is left of the header
/// once they are gone.
fn c_structs(source: &str) -> (BTreeMap<String, Fields>, String) {
    let mut structs = BTreeMap::new();
    let mut remainder = String::new();
    let mut rest = source;
    while let Some(at) = rest.find("typedef struct {") {
        remainder.push_str(&rest[..at]);
        rest = &rest[at..];
        let open = rest.find('{').expect("a struct has a body");
        let close = rest.find('}').expect("a struct body ends");
        let end = rest[close..].find(';').expect("a typedef ends") + close;
        let name = rest[close + 1..end].trim().to_owned();
        let members = rest[open + 1..close]
            .split(';')
            .map(str::trim)
            .filter(|member| !member.is_empty())
            .map(declaration)
            .collect();
        structs.insert(name, members);
        rest = &rest[end + 1..];
    }
    remainder.push_str(rest);
    (structs, remainder)
}

fn c_functions(source: &str) -> BTreeMap<String, Function> {
    let mut functions = BTreeMap::new();
    for statement in source.split(';') {
        let statement = statement.trim();
        if statement.is_empty() || statement.starts_with("typedef") || !statement.contains('(') {
            continue;
        }
        let open = statement.find('(').expect("checked just above");
        let (name, returns) = declaration(&statement[..open]);
        let close = statement.rfind(')').expect("a parameter list ends");
        let params = statement[open + 1..close]
            .split(',')
            .map(str::trim)
            .filter(|param| !param.is_empty())
            .map(declaration)
            .collect();
        functions.insert(name, Function { returns, params });
    }
    functions
}

/// A C declaration — `const char *host`, `uint32_t width`, `void` — as the name
/// it declares and the type it declares it as. Returned name first, because
/// that is the order both callers want.
fn declaration(text: &str) -> (String, String) {
    let text = text.trim();
    let at = text.rfind(|c: char| !(c.is_alphanumeric() || c == '_')).map_or(0, |at| at + 1);
    (text[at..].to_owned(), squash(&text[..at]))
}

// ── The comparison ───────────────────────────────────────────────────────────

#[test]
fn the_header_declares_what_the_rust_exports() {
    let rust = rust_source();
    let rust_functions = rust_functions(&rust);
    let rust_structs = rust_structs(&rust);

    let (c_structs, rest) = c_structs(&c_source());
    let c_functions = c_functions(&rest);

    assert!(!rust_functions.is_empty(), "the Rust parser found no functions, so it is broken rather than passing");
    assert!(!rust_structs.is_empty(), "the Rust parser found no structs, so it is broken rather than passing");

    fn names<T>(map: &BTreeMap<String, T>) -> Vec<String> {
        map.keys().cloned().collect()
    }
    assert_eq!(names(&rust_functions), names(&c_functions), "the two halves declare different functions");
    assert_eq!(names(&rust_structs), names(&c_structs), "the two halves declare different structs");

    for (name, function) in &rust_functions {
        assert_eq!(function, &c_functions[name], "{name} differs between the header and the Rust");
    }
    for (name, members) in &rust_structs {
        assert_eq!(members, &c_structs[name], "{name} differs between the header and the Rust");
    }
}
