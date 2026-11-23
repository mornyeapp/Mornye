//! A small tolerant XML reader for what DLNA devices send. Real renderers
//! emit stray `&`, mismatched or unclosed tags, odd namespace prefixes and
//! CDATA, so this never fails: it keeps what it can read. Names are local
//! (prefixes dropped) and compared without case.

/// Deeper nesting is flattened into the deepest element kept.
const MAX_DEPTH: usize = 64;

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub(crate) struct Element {
    pub(crate) name: String,
    pub(crate) attributes: Vec<(String, String)>,
    pub(crate) children: Vec<Element>,
    pub(crate) text: String,
}

impl Element {
    pub(crate) fn is(&self, name: &str) -> bool {
        self.name.eq_ignore_ascii_case(name)
    }

    pub(crate) fn child(&self, name: &str) -> Option<&Element> {
        self.children.iter().find(|child| child.is(name))
    }

    pub(crate) fn children<'a>(&'a self, name: &'a str) -> impl Iterator<Item = &'a Element> {
        self.children.iter().filter(move |child| child.is(name))
    }

    /// The first element named `name` here or below, depth first.
    pub(crate) fn find(&self, name: &str) -> Option<&Element> {
        if self.is(name) {
            return Some(self);
        }
        self.children.iter().find_map(|child| child.find(name))
    }

    /// The trimmed text of the child `name`, empty when missing.
    pub(crate) fn text_of(&self, name: &str) -> &str {
        self.child(name).map_or("", |child| child.text.trim())
    }

    #[cfg(test)]
    pub(crate) fn attribute(&self, name: &str) -> Option<&str> {
        self.attributes
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }
}

/// The document as an unnamed root holding the top-level elements.
pub(crate) fn parse(input: &str) -> Element {
    let mut stack = vec![Element::default()];
    let mut rest = input;
    while !rest.is_empty() {
        let Some(open) = rest.find('<') else {
            append_text(&mut stack, &decode(rest));
            break;
        };
        append_text(&mut stack, &decode(&rest[..open]));
        rest = &rest[open..];
        if let Some(body) = rest.strip_prefix("<![CDATA[") {
            let end = body.find("]]>").unwrap_or(body.len());
            append_text(&mut stack, &body[..end]);
            rest = body.get(end + 3..).unwrap_or_default();
        } else if let Some(body) = rest.strip_prefix("<!--") {
            rest = body.find("-->").map_or("", |end| &body[end + 3..]);
        } else if rest.starts_with("<?") || rest.starts_with("<!") {
            rest = rest.find('>').map_or("", |end| &rest[end + 1..]);
        } else if let Some(body) = rest.strip_prefix("</") {
            let end = body.find('>').unwrap_or(body.len());
            close(&mut stack, local(body[..end].trim()));
            rest = body.get(end + 1..).unwrap_or_default();
        } else {
            let (end, resume) = tag_end(rest);
            let tag = &rest[1..end];
            rest = &rest[resume..];
            let (tag, empty) = match tag.strip_suffix('/') {
                Some(tag) => (tag, true),
                None => (tag, false),
            };
            let (name, attributes) = split_tag(tag);
            if name.is_empty() {
                // A lone `<` in text.
                append_text(&mut stack, "<");
                continue;
            }
            let element = Element {
                name: local(name).to_owned(),
                attributes,
                ..Element::default()
            };
            if empty || stack.len() > MAX_DEPTH {
                push_child(&mut stack, element);
            } else {
                stack.push(element);
            }
        }
    }
    while stack.len() > 1 {
        let element = stack.pop().expect("open element");
        push_child(&mut stack, element);
    }
    stack.pop().unwrap_or_default()
}

/// Where the tag at the start of `text` ends (its `>` outside quotes, or a
/// `<` that starts the next one) and where reading resumes.
fn tag_end(text: &str) -> (usize, usize) {
    let mut quote = None;
    for (index, byte) in text.bytes().enumerate().skip(1) {
        match (quote, byte) {
            (None, b'"' | b'\'') => quote = Some(byte),
            (Some(open), _) if open == byte => quote = None,
            (None, b'>') => return (index, index + 1),
            (None, b'<') => return (index, index),
            _ => {}
        }
    }
    (text.len(), text.len())
}

fn split_tag(tag: &str) -> (&str, Vec<(String, String)>) {
    let tag = tag.trim();
    let name_end = tag.find(|c: char| c.is_whitespace()).unwrap_or(tag.len());
    let name = &tag[..name_end];
    if name.starts_with(|c: char| !(c.is_alphanumeric() || c == '_' || c == ':')) {
        return ("", Vec::new());
    }
    let mut attributes = Vec::new();
    let mut rest = tag[name_end..].trim_start();
    while !rest.is_empty() {
        let key_end = rest
            .find(|c: char| c == '=' || c.is_whitespace())
            .unwrap_or(rest.len());
        let key = local(&rest[..key_end]).to_owned();
        rest = rest[key_end..].trim_start();
        let Some(after) = rest.strip_prefix('=') else {
            if !key.is_empty() {
                attributes.push((key, String::new()));
            }
            continue;
        };
        rest = after.trim_start();
        let (value, after) = match rest.chars().next().filter(|c| *c == '"' || *c == '\'') {
            Some(quote) => {
                let body = &rest[1..];
                let end = body.find(quote).unwrap_or(body.len());
                (&body[..end], body.get(end + 1..).unwrap_or_default())
            }
            None => rest.split_at(rest.find(char::is_whitespace).unwrap_or(rest.len())),
        };
        attributes.push((key, decode(value)));
        rest = after;
        rest = rest.trim_start();
    }
    (name, attributes)
}

fn local(name: &str) -> &str {
    name.rsplit(':').next().unwrap_or(name)
}

fn append_text(stack: &mut [Element], text: &str) {
    if let Some(open) = stack.last_mut() {
        open.text.push_str(text);
    }
}

fn push_child(stack: &mut [Element], element: Element) {
    if let Some(parent) = stack.last_mut() {
        parent.children.push(element);
    }
}

/// Closes the innermost open `name`, and what was left open inside it; a
/// close tag matching nothing open is ignored.
fn close(stack: &mut Vec<Element>, name: &str) {
    let Some(at) = stack
        .iter()
        .skip(1)
        .rposition(|element| element.is(name))
        .map(|index| index + 1)
    else {
        return;
    };
    while stack.len() > at {
        let element = stack.pop().expect("open element");
        push_child(stack, element);
    }
}

/// Resolves the five predefined entities and character references; anything
/// else, such as a bare `&`, stays as written.
pub(crate) fn decode(text: &str) -> String {
    if !text.contains('&') {
        return text.to_owned();
    }
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(at) = rest.find('&') {
        out.push_str(&rest[..at]);
        rest = &rest[at..];
        let reference = (rest.bytes().take(12))
            .position(|byte| byte == b';')
            .map(|end| &rest[1..end]);
        let resolved = reference.and_then(|name| match name {
            "lt" => Some('<'),
            "gt" => Some('>'),
            "amp" => Some('&'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            _ => {
                let number = name.strip_prefix('#')?;
                let code = match number.strip_prefix(['x', 'X']) {
                    Some(hex) => u32::from_str_radix(hex, 16).ok()?,
                    None => number.parse().ok()?,
                };
                char::from_u32(code)
            }
        });
        match (resolved, reference) {
            (Some(character), Some(name)) => {
                out.push(character);
                rest = &rest[name.len() + 2..];
            }
            _ => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

/// Escapes text for an element body or a quoted attribute.
pub(crate) fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for character in text.chars() {
        match character {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            // Control characters other than tab and line breaks are not XML.
            c if c.is_control() && !matches!(c, '\t' | '\n' | '\r') => {}
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn well_formed_documents_read_with_namespaces_dropped() {
        let root = parse(
            r#"<?xml version="1.0"?><s:Envelope xmlns:s="x"><s:Body>
            <u:GetVolumeResponse xmlns:u="y"><CurrentVolume>42</CurrentVolume>
            </u:GetVolumeResponse></s:Body></s:Envelope>"#,
        );
        let response = root.find("getvolumeresponse").unwrap();
        assert_eq!(response.text_of("CurrentVolume"), "42");
        assert_eq!(root.find("Envelope").unwrap().attribute("s"), Some("x"));
    }

    #[test]
    fn sloppy_documents_keep_what_can_be_read() {
        let root = parse(
            "<root><device><friendlyName>Den & Hall &amp; More &#x263A;</friendlyName>\
             <modelName><![CDATA[Model <5>]]></modelName><br><deviceType>t</deviceType>\
             <icon width=32 height='3'2/></device><stray></nothing></root>",
        );
        let device = root.find("device").unwrap();
        assert_eq!(device.text_of("friendlyName"), "Den & Hall & More \u{263A}");
        assert_eq!(device.text_of("modelName"), "Model <5>");
        // The unclosed `<br>` swallows its siblings, which stay findable.
        assert_eq!(root.find("deviceType").unwrap().text, "t");
        assert_eq!(root.find("icon").unwrap().attribute("width"), Some("32"));
        assert!(root.find("stray").is_some());
    }

    #[test]
    fn broken_input_never_panics() {
        for input in [
            "",
            "<",
            "<<",
            "</",
            "<a",
            "<a b='",
            "<!--",
            "<![CDATA[",
            "&",
            "&#xFFFFFFFF;",
            "<a>&#;</a",
            "<a></b></a>",
            "<:/>",
            "<a =x>",
            "<é>t</é>",
        ] {
            let _ = parse(input);
        }
        let deep = "<a>".repeat(500);
        assert!(parse(&deep).find("a").is_some());
    }

    #[test]
    fn text_escapes_and_decodes_back() {
        let text = "Rock & Roll <Live> \"1\" 'a'\u{1}";
        assert_eq!(decode(&escape(text)), "Rock & Roll <Live> \"1\" 'a'");
    }
}
