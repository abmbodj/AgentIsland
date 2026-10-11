//! Formatting-preserving JSON edits: parse once for byte spans, then splice text.
//! Untouched bytes stay identical, and new text copies the file's own indent and `:` style.
use serde_json::Value;

#[derive(Debug, Clone)]
pub enum Node {
    Obj { start: usize, end: usize, members: Vec<(String, usize, Node)> },
    Arr { start: usize, end: usize, items: Vec<Node> },
    Scalar { start: usize, end: usize },
}

impl Node {
    pub fn start(&self) -> usize {
        match self {
            Node::Obj { start, .. } | Node::Arr { start, .. } | Node::Scalar { start, .. } => *start,
        }
    }
    pub fn end(&self) -> usize {
        match self {
            Node::Obj { end, .. } | Node::Arr { end, .. } | Node::Scalar { end, .. } => *end,
        }
    }
    pub fn get(&self, key: &str) -> Option<&Node> {
        match self {
            Node::Obj { members, .. } => members.iter().find(|(k, _, _)| k == key).map(|(_, _, v)| v),
            _ => None,
        }
    }
}

struct P<'a> {
    b: &'a [u8],
    i: usize,
}

impl P<'_> {
    fn ws(&mut self) {
        while self.i < self.b.len() && self.b[self.i].is_ascii_whitespace() {
            self.i += 1;
        }
    }
    fn err<T>(&self) -> Result<T, String> {
        Err(format!("invalid JSON at byte {}", self.i))
    }
    fn string(&mut self) -> Result<(), String> {
        self.i += 1;
        while self.i < self.b.len() {
            match self.b[self.i] {
                b'\\' => self.i += 2,
                b'"' => {
                    self.i += 1;
                    return Ok(());
                }
                _ => self.i += 1,
            }
        }
        self.err()
    }
    fn value(&mut self) -> Result<Node, String> {
        self.ws();
        let start = self.i;
        match self.b.get(self.i) {
            Some(b'{') => {
                self.i += 1;
                let mut members = vec![];
                loop {
                    self.ws();
                    match self.b.get(self.i) {
                        Some(b'}') if members.is_empty() => break,
                        Some(b'"') => {}
                        _ => return self.err(),
                    }
                    let ks = self.i;
                    self.string()?;
                    let key: String = serde_json::from_slice(&self.b[ks..self.i]).map_err(|e| e.to_string())?;
                    self.ws();
                    if self.b.get(self.i) != Some(&b':') {
                        return self.err();
                    }
                    self.i += 1;
                    let v = self.value()?;
                    members.push((key, ks, v));
                    self.ws();
                    match self.b.get(self.i) {
                        Some(b',') => self.i += 1,
                        Some(b'}') => break,
                        _ => return self.err(),
                    }
                }
                self.i += 1;
                Ok(Node::Obj { start, end: self.i, members })
            }
            Some(b'[') => {
                self.i += 1;
                let mut items = vec![];
                loop {
                    self.ws();
                    if self.b.get(self.i) == Some(&b']') && items.is_empty() {
                        break;
                    }
                    items.push(self.value()?);
                    self.ws();
                    match self.b.get(self.i) {
                        Some(b',') => self.i += 1,
                        Some(b']') => break,
                        _ => return self.err(),
                    }
                }
                self.i += 1;
                Ok(Node::Arr { start, end: self.i, items })
            }
            Some(b'"') => {
                self.string()?;
                Ok(Node::Scalar { start, end: self.i })
            }
            Some(_) => {
                while self.i < self.b.len() && !b",}] \t\r\n".contains(&self.b[self.i]) {
                    self.i += 1;
                }
                if self.i == start { self.err() } else { Ok(Node::Scalar { start, end: self.i }) }
            }
            None => self.err(),
        }
    }
}

/// Parse and validate a whole document (strictness delegated to serde_json).
pub fn parse(s: &str) -> Result<Node, String> {
    serde_json::from_str::<Value>(s).map_err(|e| e.to_string())?;
    let mut p = P { b: s.as_bytes(), i: 0 };
    p.value()
}

/// The file's indent unit and key separator, e.g. ("  ", ": ") or ("  ", " : ").
#[derive(Debug, Clone)]
pub struct Style {
    pub indent: String,
    pub sep: String,
}

pub fn style(s: &str, root: &Node) -> Style {
    let mut st = Style { indent: "  ".into(), sep: ": ".into() };
    if let Node::Obj { members, .. } = root {
        if let Some((_, ks, v)) = members.first() {
            let line_start = s[..*ks].rfind('\n').map_or(0, |i| i + 1);
            let ind = &s[line_start..*ks];
            if !ind.is_empty() && ind.chars().all(|c| c == ' ' || c == '\t') {
                st.indent = ind.to_string();
            }
            st.sep = s[closing_quote(s, *ks) + 1..v.start()].to_string();
        }
    }
    st
}

fn closing_quote(s: &str, open: usize) -> usize {
    let b = s.as_bytes();
    let mut i = open + 1;
    while i < b.len() {
        match b[i] {
            b'\\' => i += 2,
            b'"' => return i,
            _ => i += 1,
        }
    }
    i
}

/// Pretty-print `v` as if it starts at nesting `level` (first line unindented).
pub fn render(v: &Value, level: usize, st: &Style) -> String {
    let ind = |l: usize| st.indent.repeat(l);
    match v {
        Value::Object(m) if !m.is_empty() => {
            let inner: Vec<String> = m
                .iter()
                .map(|(k, v)| format!("{}{}{}{}", ind(level + 1), Value::String(k.clone()), st.sep, render(v, level + 1, st)))
                .collect();
            format!("{{\n{}\n{}}}", inner.join(",\n"), ind(level))
        }
        Value::Array(a) if !a.is_empty() => {
            let inner: Vec<String> = a.iter().map(|v| format!("{}{}", ind(level + 1), render(v, level + 1, st))).collect();
            format!("[\n{}\n{}]", inner.join(",\n"), ind(level))
        }
        _ => v.to_string(),
    }
}

fn splice(s: &str, from: usize, to: usize, text: &str) -> String {
    format!("{}{}{}", &s[..from], text, &s[to..])
}

/// Append `"key": value` to an object at nesting `level`.
pub fn insert_member(s: &str, obj: &Node, level: usize, key: &str, value: &Value, st: &Style) -> String {
    let Node::Obj { start, end, members } = obj else { return s.to_string() };
    let ind = st.indent.repeat(level + 1);
    let member = format!("{ind}{}{}{}", Value::String(key.into()), st.sep, render(value, level + 1, st));
    match members.last() {
        Some((_, _, last)) => splice(s, last.end(), last.end(), &format!(",\n{member}")),
        None => splice(s, start + 1, end - 1, &format!("\n{member}\n{}", st.indent.repeat(level))),
    }
}

/// Append an item to an array at nesting `level`.
pub fn append_item(s: &str, arr: &Node, level: usize, value: &Value, st: &Style) -> String {
    let Node::Arr { start, end, items } = arr else { return s.to_string() };
    let item = format!("{}{}", st.indent.repeat(level + 1), render(value, level + 1, st));
    match items.last() {
        Some(last) => splice(s, last.end(), last.end(), &format!(",\n{item}")),
        None => splice(s, start + 1, end - 1, &format!("\n{item}\n{}", st.indent.repeat(level))),
    }
}

/// Remove the i-th member/item, taking exactly the separator text that insertion added.
pub fn remove_child(s: &str, parent: &Node, i: usize) -> String {
    let (start, end, spans): (usize, usize, Vec<(usize, usize)>) = match parent {
        Node::Obj { start, end, members } => (*start, *end, members.iter().map(|(_, ks, v)| (*ks, v.end())).collect()),
        Node::Arr { start, end, items } => (*start, *end, items.iter().map(|v| (v.start(), v.end())).collect()),
        Node::Scalar { .. } => return s.to_string(),
    };
    if spans.len() == 1 {
        splice(s, start + 1, end - 1, "")
    } else if i > 0 {
        splice(s, spans[i - 1].1, spans[i].1, "")
    } else {
        splice(s, spans[0].0, spans[1].0, "")
    }
}

pub fn replace(s: &str, node: &Node, text: &str) -> String {
    splice(s, node.start(), node.end(), text)
}
