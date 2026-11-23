//! A renderer's device description (UPnP Device Architecture 1.1 section 2):
//! its name, model, UDN and the control URLs of AVTransport,
//! RenderingControl and ConnectionManager. The renderer can be the root
//! device or one embedded in a `deviceList`.

use crate::xml::{self, Element};
use url::Url;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Service {
    /// The exact type the device declared; SOAP actions are named after it.
    pub(crate) ty: String,
    pub(crate) control: Url,
    pub(crate) scpd: Option<Url>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Renderer {
    pub(crate) udn: String,
    pub(crate) name: String,
    pub(crate) model: String,
    pub(crate) transport: Service,
    pub(crate) rendering: Option<Service>,
    pub(crate) connection: Option<Service>,
}

/// The renderer `location` describes, preferring the device `udn` names.
/// `None` when no device in it has an AVTransport service.
pub(crate) fn parse(text: &str, location: &Url, udn: Option<&str>) -> Option<Renderer> {
    let root = xml::parse(text);
    // UPnP 1.0 devices may set a base for relative URLs; it must stay on
    // the device that answered.
    let base = root
        .find("URLBase")
        .and_then(|base| Url::parse(base.text.trim()).ok())
        .filter(|base| same_host(base, location))
        .unwrap_or_else(|| location.clone());
    let mut devices = Vec::new();
    collect_devices(&root, &mut devices);
    let renders = |device: &&Element| service(device, "AVTransport", &base, location).is_some();
    let candidates = || devices.iter().copied().filter(renders);
    let chosen = candidates()
        .find(|device| udn.is_some_and(|udn| device.text_of("UDN").eq_ignore_ascii_case(udn)))
        .or_else(|| {
            candidates().find(|device| {
                device
                    .text_of("deviceType")
                    .to_ascii_lowercase()
                    .contains(":device:mediarenderer:")
            })
        })
        .or_else(|| candidates().next())?;
    let name = [chosen.text_of("friendlyName"), chosen.text_of("modelName")]
        .into_iter()
        .find(|name| !name.is_empty())
        .unwrap_or("DLNA device");
    let model = [chosen.text_of("modelName"), chosen.text_of("manufacturer")]
        .into_iter()
        .find(|model| !model.is_empty())
        .unwrap_or_default();
    Some(Renderer {
        udn: chosen.text_of("UDN").to_owned(),
        name: name.to_owned(),
        model: model.to_owned(),
        transport: service(chosen, "AVTransport", &base, location)?,
        rendering: service(chosen, "RenderingControl", &base, location),
        connection: service(chosen, "ConnectionManager", &base, location),
    })
}

fn collect_devices<'a>(element: &'a Element, out: &mut Vec<&'a Element>) {
    if element.is("device") {
        out.push(element);
    }
    for child in &element.children {
        collect_devices(child, out);
    }
}

/// The device's own service of `kind` (not an embedded device's).
fn service(device: &Element, kind: &str, base: &Url, location: &Url) -> Option<Service> {
    let wanted = format!(":service:{}:", kind.to_ascii_lowercase());
    let entry = device
        .child("serviceList")?
        .children("service")
        .find(|service| {
            service
                .text_of("serviceType")
                .to_ascii_lowercase()
                .contains(&wanted)
        })?;
    let resolve = |name: &str| {
        Some(entry.text_of(name))
            .filter(|path| !path.is_empty())
            .and_then(|path| base.join(path).ok())
            .filter(|url| url.scheme() == "http" && same_host(url, location))
    };
    Some(Service {
        ty: entry.text_of("serviceType").to_owned(),
        control: resolve("controlURL")?,
        scpd: resolve("SCPDURL"),
    })
}

fn same_host(url: &Url, location: &Url) -> bool {
    url.host() == location.host()
}

/// The largest `Volume` the RenderingControl description allows; UPnP
/// leaves it to the vendor, and most use 100.
pub(crate) fn volume_maximum(scpd: &str) -> Option<u32> {
    let root = xml::parse(scpd);
    let table = root.find("serviceStateTable")?;
    table
        .children("stateVariable")
        .find(|variable| variable.text_of("name").eq_ignore_ascii_case("Volume"))?
        .child("allowedValueRange")?
        .text_of("maximum")
        .parse()
        .ok()
        .filter(|maximum| *maximum > 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn location() -> Url {
        Url::parse("http://192.0.2.30:49152/desc/device.xml").unwrap()
    }

    #[test]
    fn an_embedded_renderer_resolves_relative_urls() {
        let text = r#"<?xml version="1.0"?>
            <root xmlns="urn:schemas-upnp-org:device-1-0"><specVersion><major>1</major></specVersion>
            <device><deviceType>urn:schemas-upnp-org:device:Basic:1</deviceType>
              <friendlyName>Hall TV</friendlyName><UDN>uuid:root-1</UDN>
              <deviceList><device>
                <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
                <friendlyName>Hall TV &amp; Sound</friendlyName><manufacturer>Maker</manufacturer>
                <UDN>uuid:renderer-1</UDN>
                <serviceList>
                  <service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
                    <SCPDURL>avt.xml</SCPDURL><controlURL>/upnp/control/avt</controlURL></service>
                  <service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
                    <SCPDURL>/rc.xml</SCPDURL><controlURL>rc/control</controlURL></service>
                </serviceList>
              </device></deviceList>
            </device></root>"#;
        let renderer = parse(text, &location(), None).unwrap();
        assert_eq!(renderer.udn, "uuid:renderer-1");
        assert_eq!(renderer.name, "Hall TV & Sound");
        assert_eq!(renderer.model, "Maker");
        assert_eq!(
            renderer.transport.control.as_str(),
            "http://192.0.2.30:49152/upnp/control/avt"
        );
        assert_eq!(
            renderer.transport.scpd.unwrap().as_str(),
            "http://192.0.2.30:49152/desc/avt.xml"
        );
        assert_eq!(
            renderer.rendering.unwrap().control.as_str(),
            "http://192.0.2.30:49152/desc/rc/control"
        );
        assert!(renderer.connection.is_none());
    }

    #[test]
    fn sloppy_descriptions_with_a_base_still_parse() {
        // Prefixed names, a stray `&`, an unclosed tag, odd case, a URLBase.
        let text = "<u:root><URLBase>http://192.0.2.30:8080/</URLBase><u:device>\
            <friendlyName>Den & Kitchen</friendlyName><modelName>Speaker 2<br></modelName>\
            <UDN> uuid:speaker-2 </UDN><serviceList><service>\
            <serviceType>urn:schemas-upnp-org:service:avtransport:2</serviceType>\
            <controlURL>AVTransport/ctrl</controlURL></service></serviceList></u:device>";
        let renderer = parse(text, &location(), Some("uuid:speaker-2")).unwrap();
        assert_eq!(renderer.name, "Den & Kitchen");
        assert_eq!(renderer.udn, "uuid:speaker-2");
        assert_eq!(
            renderer.transport.ty,
            "urn:schemas-upnp-org:service:avtransport:2"
        );
        assert_eq!(
            renderer.transport.control.as_str(),
            "http://192.0.2.30:8080/AVTransport/ctrl"
        );
    }

    #[test]
    fn devices_without_a_transport_or_pointing_elsewhere_are_skipped() {
        let server = "<root><device><friendlyName>NAS</friendlyName><serviceList><service>\
            <serviceType>urn:schemas-upnp-org:service:ContentDirectory:1</serviceType>\
            <controlURL>/cd</controlURL></service></serviceList></device></root>";
        assert!(parse(server, &location(), None).is_none());
        let elsewhere = "<root><device><serviceList><service>\
            <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>\
            <controlURL>http://198.51.100.1/avt</controlURL></service></serviceList></device></root>";
        assert!(parse(elsewhere, &location(), None).is_none());
        assert!(parse("garbage <<<", &location(), None).is_none());
    }

    #[test]
    fn the_volume_range_comes_from_the_service_description() {
        let scpd = "<scpd><serviceStateTable><stateVariable sendEvents=\"no\"><name>Mute</name>\
            </stateVariable><stateVariable><name>Volume</name><dataType>ui2</dataType>\
            <allowedValueRange><minimum>0</minimum><maximum>60</maximum><step>1</step>\
            </allowedValueRange></stateVariable></serviceStateTable></scpd>";
        assert_eq!(volume_maximum(scpd), Some(60));
        assert_eq!(volume_maximum("<scpd/>"), None);
    }
}
