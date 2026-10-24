use super::*;
use crate::subsonic::xml::{NAMESPACE, document};

async fn xml_text(fixture: &Fixture, method: &str, params: &[(&str, &str)]) -> String {
    let reply = fixture.raw(method, params, HeaderMap::new()).await;
    assert_eq!(reply.status, 200);
    assert_eq!(reply.header("content-type"), Some(XML_TYPE));
    reply.text()
}

fn child<'a, 'input>(node: roxmltree::Node<'a, 'input>, name: &str) -> roxmltree::Node<'a, 'input> {
    node.children()
        .find(|child| child.is_element() && child.tag_name().name() == name)
        .unwrap_or_else(|| panic!("<{name}> under <{}>", node.tag_name().name()))
}

fn children<'a, 'input>(
    node: roxmltree::Node<'a, 'input>,
    name: &'a str,
) -> impl Iterator<Item = roxmltree::Node<'a, 'input>> + 'a {
    node.children()
        .filter(move |child| child.is_element() && child.tag_name().name() == name)
}

#[test]
fn converter_maps_objects_scalars_arrays_and_values() {
    // Keys are written sorted so the output is the same with or without
    // serde_json's `preserve_order`.
    let body = json!({
        "album": {
            "count": 2,
            "empty": [],
            "flag": true,
            "id": "al-1",
            "skip": null,
            "song": [{ "id": "a" }, { "id": "b", "value": "text & more" }],
            "tags": ["x", 1],
        },
        "status": "ok",
    });
    assert_eq!(
        document("subsonic-response", body.as_object().expect("object")),
        concat!(
            r#"<?xml version="1.0" encoding="UTF-8"?>"#,
            r#"<subsonic-response xmlns="http://subsonic.org/restapi" status="ok">"#,
            r#"<album count="2" flag="true" id="al-1">"#,
            r#"<song id="a"/><song id="b">text &amp; more</song>"#,
            r#"<tags>x</tags><tags>1</tags>"#,
            r#"</album></subsonic-response>"#,
        )
    );
}

#[tokio::test]
async fn nested_responses_render_as_subsonic_xml() {
    let fixture = library();
    let blue = fixture.album_id("l:1");
    let text = xml_text(&fixture, "getAlbum", &[("id", &blue)]).await;
    assert_eq!(
        text,
        xml_text(&fixture, "getAlbum", &[("id", &blue), ("f", "xml")]).await
    );
    let document = roxmltree::Document::parse(&text).expect("well-formed XML");
    let root = document.root_element();
    assert_eq!(root.tag_name().name(), "subsonic-response");
    assert_eq!(root.tag_name().namespace(), Some(NAMESPACE));
    assert_eq!(root.attribute("status"), Some("ok"));
    assert_eq!(root.attribute("version"), Some("1.16.1"));
    assert_eq!(root.attribute("type"), Some("mornye"));
    assert_eq!(root.attribute("serverVersion"), Some(APP_VERSION));
    assert_eq!(root.attribute("openSubsonic"), Some("true"));
    let album = child(root, "album");
    assert_eq!(album.attribute("id"), Some(blue.as_str()));
    assert_eq!(album.attribute("songCount"), Some("3"));
    let songs: Vec<&str> = children(album, "song")
        .map(|song| song.attribute("id").expect("id"))
        .collect();
    assert_eq!(songs, ["l:1", "l:2", "l:3"]);
    let first = children(album, "song").next().expect("song");
    assert_eq!(first.attribute("isDir"), Some("false"));
    assert_eq!(first.attribute("duration"), Some("200"));
    assert_eq!(child(first, "artists").attribute("name"), Some("The Band"));
    assert_eq!(child(first, "genres").attribute("name"), Some("Rock"));

    let song = roxmltree::Document::parse(&xml_text(&fixture, "getSong", &[("id", "l:10")]).await)
        .expect("well-formed XML")
        .root_element()
        .children()
        .find(|node| node.has_tag_name((NAMESPACE, "song")))
        .map(|node| {
            (
                node.attribute("title").map(str::to_owned),
                child(node, "replayGain")
                    .attribute("trackGain")
                    .map(str::to_owned),
                child(node, "isrc").text().map(str::to_owned),
            )
        })
        .expect("song");
    assert_eq!(
        song,
        (
            Some("Halo".to_owned()),
            Some("-4.2".to_owned()),
            Some("USSM10800001".to_owned())
        )
    );
}

#[tokio::test]
async fn genre_names_and_extension_versions_are_text_content() {
    let fixture = library();
    let genres = xml_text(&fixture, "getGenres", &[]).await;
    let document = roxmltree::Document::parse(&genres).expect("well-formed XML");
    let genre = child(child(document.root_element(), "genres"), "genre");
    assert_eq!(genre.text(), Some("pop"));
    assert_eq!(genre.attribute("songCount"), Some("3"));
    assert_eq!(genre.attribute("albumCount"), Some("2"));
    assert_eq!(genre.attribute("value"), None);
    let extensions = xml_text(&fixture, "getOpenSubsonicExtensions", &[]).await;
    assert!(
        extensions.contains(
            r#"<openSubsonicExtensions name="apiKeyAuthentication"><versions>1</versions></openSubsonicExtensions>"#
        ),
        "{extensions}"
    );
    let ping = xml_text(&fixture, "ping", &[]).await;
    assert!(ping.ends_with("/>"), "an empty root: {ping}");
}

#[tokio::test]
async fn markup_and_control_characters_are_escaped() {
    let fixture = Fixture::new(|_| {
        vec![json!({
            "id": "s&1", "title": "Rock & \"Roll\" <Live> 'x'\u{1}\ttab", "artist": "A",
            "path": "/m/s.flac",
        })]
    });
    let text = xml_text(&fixture, "getSong", &[("id", "s&1")]).await;
    let document = roxmltree::Document::parse(&text).expect("well-formed XML");
    let song = child(document.root_element(), "song");
    assert_eq!(song.attribute("id"), Some("s&1"));
    assert_eq!(
        song.attribute("title"),
        Some("Rock & \"Roll\" <Live> 'x'\ttab"),
        "the control character is dropped, the tab kept"
    );
}
