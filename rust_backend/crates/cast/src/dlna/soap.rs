//! UPnP control over SOAP (UPnP Device Architecture 1.1 section 3), the
//! AVTransport time format and the DIDL-Lite metadata of a song.

use super::description::Service;
use crate::http;
use crate::media::dlna_features;
use crate::session::Item;
use crate::xml::{self, escape};
use http::Reply;
use std::time::Duration;

/// SOAP answers are small; position answers repeat the song's metadata.
const MAX_ANSWER: usize = 128 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Failure {
    /// No answer, or one that is not SOAP.
    Unreachable,
    /// A UPnP error: its code (0 when missing) and description.
    Fault(u32, String),
}

impl Failure {
    pub(crate) fn code(&self) -> Option<u32> {
        match self {
            Self::Fault(code, _) => Some(*code),
            Self::Unreachable => None,
        }
    }
}

pub(crate) type Answer = Vec<(String, String)>;

pub(crate) fn value<'a>(answer: &'a Answer, name: &str) -> &'a str {
    answer
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case(name))
        .map_or("", |(_, value)| value.trim())
}

pub(crate) fn envelope(service: &str, action: &str, arguments: &[(&str, &str)]) -> String {
    let mut body = String::new();
    for (name, value) in arguments {
        body.push_str(&format!("<{name}>{}</{name}>", escape(value)));
    }
    format!(
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n\
         <s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" \
         s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>\
         <u:{action} xmlns:u=\"{}\">{body}</u:{action}></s:Body></s:Envelope>",
        escape(service)
    )
}

pub(crate) async fn call(
    service: &Service,
    action: &str,
    arguments: &[(&str, &str)],
    timeout: Duration,
) -> Result<Answer, Failure> {
    let soap_action = format!("\"{}#{action}\"", service.ty);
    let headers = [
        ("Content-Type", "text/xml; charset=\"utf-8\""),
        ("SOAPAction", soap_action.as_str()),
        ("User-Agent", "UPnP/1.0 DLNADOC/1.50 Mornye/1.0"),
    ];
    let reply = http::request(
        ::http::Method::POST,
        &service.control,
        &headers,
        envelope(&service.ty, action, arguments),
        MAX_ANSWER,
        timeout,
    )
    .await
    .map_err(|_| Failure::Unreachable)?;
    answer(&reply, action)
}

/// The output arguments of `action`, or the fault the device sent.
pub(crate) fn answer(reply: &Reply, action: &str) -> Result<Answer, Failure> {
    let root = xml::parse(&reply.body);
    if reply.status.is_success()
        && let Some(response) = root.find(&format!("{action}Response"))
    {
        return Ok(response
            .children
            .iter()
            .map(|argument| (argument.name.clone(), argument.text.clone()))
            .collect());
    }
    match root.find("UPnPError") {
        Some(error) => Err(Failure::Fault(
            error.text_of("errorCode").parse().unwrap_or_default(),
            error.text_of("errorDescription").to_owned(),
        )),
        // Some devices answer success with an empty body.
        None if reply.status.is_success() && reply.body.trim().is_empty() => Ok(Vec::new()),
        None => Err(Failure::Unreachable),
    }
}

/// `H+:MM:SS[.F+]` or `H+:MM:SS[.F0/F1]` in seconds; `None` for
/// `NOT_IMPLEMENTED` and anything unreadable.
pub(crate) fn seconds(text: &str) -> Option<f64> {
    let text = text.trim();
    let mut parts = text.split(':');
    let (hours, minutes, rest) = (parts.next()?, parts.next()?, parts.next()?);
    if parts.next().is_some() {
        return None;
    }
    let (whole, fraction) = rest.split_once('.').unwrap_or((rest, ""));
    let fraction = match fraction.split_once('/') {
        Some((top, bottom)) => {
            let bottom: f64 = bottom.parse().ok()?;
            (bottom > 0.0).then(|| top.parse::<f64>().ok().map(|top| top / bottom))??
        }
        None if fraction.is_empty() => 0.0,
        None => format!("0.{fraction}").parse().ok()?,
    };
    let hours: f64 = hours.trim_start_matches('+').parse().ok()?;
    let minutes: f64 = minutes.parse().ok()?;
    let whole: f64 = whole.parse().ok()?;
    let total = hours * 3600.0 + minutes * 60.0 + whole + fraction;
    (total.is_finite() && total >= 0.0).then_some(total)
}

/// A seek target in whole seconds: fractions trip some renderers.
pub(crate) fn time(seconds: f64) -> String {
    let total = seconds.max(0.0).round() as u64;
    format!(
        "{}:{:02}:{:02}",
        total / 3600,
        (total / 60) % 60,
        total % 60
    )
}

fn duration(seconds: f64) -> String {
    let millis = (seconds.max(0.0) * 1000.0).round() as u64;
    format!("{}.{:03}", time((millis / 1000) as f64), millis % 1000)
}

pub(crate) fn protocol_info(mime: &str) -> String {
    format!("http-get:*:{mime}:{}", dlna_features(mime))
}

/// Song metadata for `SetAVTransportURI`, the `res` typed `mime`.
pub(crate) fn didl(item: &Item, mime: &str) -> String {
    let mut out = String::from(
        "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\" \
         xmlns:dc=\"http://purl.org/dc/elements/1.1/\" \
         xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">\
         <item id=\"0\" parentID=\"-1\" restricted=\"1\">",
    );
    let title = if item.title.is_empty() {
        "Unknown"
    } else {
        &item.title
    };
    out.push_str(&format!("<dc:title>{}</dc:title>", escape(title)));
    if !item.artist.is_empty() {
        let artist = escape(&item.artist);
        out.push_str(&format!(
            "<dc:creator>{artist}</dc:creator><upnp:artist>{artist}</upnp:artist>"
        ));
    }
    if !item.album.is_empty() {
        out.push_str(&format!("<upnp:album>{}</upnp:album>", escape(&item.album)));
    }
    if let Some(artwork) = &item.artwork {
        out.push_str(&format!(
            "<upnp:albumArtURI>{}</upnp:albumArtURI>",
            escape(artwork)
        ));
    }
    out.push_str("<upnp:class>object.item.audioItem.musicTrack</upnp:class>");
    let length = item
        .duration
        .map(|ms| format!(" duration=\"{}\"", duration(ms as f64 / 1000.0)))
        .unwrap_or_default();
    out.push_str(&format!(
        "<res protocolInfo=\"{}\"{length}>{}</res></item></DIDL-Lite>",
        escape(&protocol_info(mime)),
        escape(&item.url)
    ));
    out
}

/// Spellings renderers use for the same audio type.
const ALIASES: &[&[&str]] = &[
    &["audio/flac", "audio/x-flac"],
    &["audio/mp4", "audio/x-m4a", "audio/m4a"],
    &["audio/mpeg", "audio/mp3", "audio/x-mpeg"],
    &["audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave"],
    &["audio/aac", "audio/x-aac", "audio/aacp"],
    &["audio/ogg", "application/ogg", "audio/x-ogg"],
];

/// `mime` as the renderer's `SinkProtocolInfo` spells it, when it lists
/// another spelling only.
pub(crate) fn sink_mime(sink: &str, mime: &str) -> String {
    let listed: Vec<String> = sink
        .split(',')
        .filter_map(|entry| entry.trim().split(':').nth(2))
        .map(str::to_ascii_lowercase)
        .collect();
    let wanted = mime.to_ascii_lowercase();
    if listed.is_empty()
        || listed
            .iter()
            .any(|listed| *listed == wanted || listed == "*")
    {
        return mime.to_owned();
    }
    ALIASES
        .iter()
        .find(|names| names.contains(&wanted.as_str()))
        .and_then(|names| names.iter().find(|name| listed.iter().any(|l| l == *name)))
        .map_or_else(|| mime.to_owned(), |name| (*name).to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ::http::StatusCode;

    fn reply(status: u16, body: &str) -> Reply {
        Reply {
            status: StatusCode::from_u16(status).unwrap(),
            body: body.into(),
        }
    }

    #[test]
    fn envelopes_escape_arguments() {
        let text = envelope(
            "urn:schemas-upnp-org:service:AVTransport:1",
            "SetAVTransportURI",
            &[("InstanceID", "0"), ("CurrentURIMetaData", "<a>&</a>")],
        );
        assert!(text.contains(
            "<u:SetAVTransportURI xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\">"
        ));
        assert!(text.contains("<CurrentURIMetaData>&lt;a&gt;&amp;&lt;/a&gt;</CurrentURIMetaData>"));
    }

    #[test]
    fn answers_and_faults_read_from_any_prefix() {
        let ok = reply(
            200,
            "<SOAP-ENV:Envelope><SOAP-ENV:Body><m:GetTransportInfoResponse>\
             <CurrentTransportState>PLAYING</CurrentTransportState>\
             <CurrentTransportStatus>OK</CurrentTransportStatus></m:GetTransportInfoResponse>\
             </SOAP-ENV:Body></SOAP-ENV:Envelope>",
        );
        let answer = answer(&ok, "GetTransportInfo").unwrap();
        assert_eq!(value(&answer, "currenttransportstate"), "PLAYING");

        let fault = reply(
            500,
            "<s:Envelope><s:Body><s:Fault><faultcode>s:Client</faultcode><detail>\
             <UPnPError xmlns=\"urn:schemas-upnp-org:control-1-0\"><errorCode>714</errorCode>\
             <errorDescription>Illegal MIME-type</errorDescription></UPnPError></detail>\
             </s:Fault></s:Body></s:Envelope>",
        );
        assert_eq!(
            super::answer(&fault, "SetAVTransportURI"),
            Err(Failure::Fault(714, "Illegal MIME-type".into()))
        );
        assert_eq!(super::answer(&reply(200, ""), "Play"), Ok(Vec::new()));
        assert_eq!(
            super::answer(&reply(404, "<html>no</html>"), "Play"),
            Err(Failure::Unreachable)
        );
    }

    #[test]
    fn times_read_every_upnp_form() {
        assert_eq!(seconds("0:03:25"), Some(205.0));
        assert_eq!(seconds("00:03:25.500"), Some(205.5));
        assert_eq!(seconds("1:00:00.1/4"), Some(3600.25));
        assert_eq!(seconds("+0:00:01"), Some(1.0));
        assert_eq!(seconds("NOT_IMPLEMENTED"), None);
        assert_eq!(seconds("0:00"), None);
        assert_eq!(seconds("0:00:01.5/0"), None);
        assert_eq!(time(3725.6), "1:02:06");
        assert_eq!(duration(185.25), "0:03:05.250");
    }

    #[test]
    fn metadata_describes_a_music_track() {
        let item = Item {
            url: "http://192.0.2.1:4000/media/a?x=1&y=2".into(),
            mime: "audio/flac".into(),
            token: 1,
            title: "Rock & Roll".into(),
            artist: "Artist".into(),
            album: String::new(),
            artwork: Some("http://192.0.2.1:4000/media/b".into()),
            duration: Some(185_250),
        };
        let didl = didl(&item, "audio/x-flac");
        let root = xml::parse(&didl);
        let entry = root.find("item").unwrap();
        assert_eq!(entry.text_of("title"), "Rock & Roll");
        assert_eq!(entry.text_of("artist"), "Artist");
        assert!(entry.child("album").is_none());
        assert_eq!(entry.text_of("class"), "object.item.audioItem.musicTrack");
        let res = entry.child("res").unwrap();
        assert_eq!(res.text, item.url);
        assert_eq!(res.attribute("duration"), Some("0:03:05.250"));
        assert_eq!(
            res.attribute("protocolInfo"),
            Some(
                "http-get:*:audio/x-flac:DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"
            )
        );
    }

    #[test]
    fn the_renderers_own_spelling_of_a_type_wins() {
        let sink = "http-get:*:audio/x-flac:*,http-get:*:audio/mpeg:DLNA.ORG_PN=MP3";
        assert_eq!(sink_mime(sink, "audio/flac"), "audio/x-flac");
        assert_eq!(sink_mime(sink, "audio/mpeg"), "audio/mpeg");
        assert_eq!(sink_mime(sink, "audio/ogg"), "audio/ogg");
        assert_eq!(sink_mime("http-get:*:*:*", "audio/flac"), "audio/flac");
        assert_eq!(sink_mime("", "audio/flac"), "audio/flac");
    }
}
