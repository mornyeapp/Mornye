(function (host, helpers) {
    "use strict";
    const object = Object;
    const keys = Object.keys;
    const isArray = Array.isArray;
    const apply = Reflect.apply;
    const stringify = JSON.stringify;
    const isView = ArrayBuffer.isView;
    const dateType = Date;
    const bufferType = ArrayBuffer;
    const mapType = Map;
    const setType = Set;
    const mapEach = Map.prototype.forEach;
    const setEach = Set.prototype.forEach;
    const stringValue = String.prototype.valueOf;
    const numberValue = Number.prototype.valueOf;
    const booleanValue = Boolean.prototype.valueOf;
    const symbolValue = Symbol.prototype.valueOf;
    const {goString, exportValue, serialize} = helpers;
    const empty = value => value === undefined || value === null;
    const trim = value => host.providerTrim(value);
    // Export happens before Go's type assertion. Traverse rejected objects too:
    // their getters can change later fields. Shared/cyclic objects are visited
    // once per Export, and unsupported JSON values are harmless if discarded.
    function exported(value, seen) {
        if (typeof value === "symbol") return goString(value);
        if (empty(value) || typeof value !== "object" || host.logOpaqueType(value) !== "") return value;
        let primitive;
        try { primitive = apply(numberValue, value, []); } catch (_) {}
        if (typeof primitive === "number") return primitive;
        try { primitive = apply(booleanValue, value, []); } catch (_) {}
        if (typeof primitive === "boolean") return primitive;
        try { primitive = apply(symbolValue, value, []); } catch (_) {}
        if (typeof primitive === "symbol") return goString(primitive);
        if (value instanceof dateType || value instanceof bufferType || isView(value)) return value;
        if (seen === undefined) seen = new mapType();
        if (seen.has(value)) return seen.get(value);
        if (isArray(value) || value instanceof setType) {
            const result = [];
            seen.set(value, result);
            if (isArray(value)) {
                const length = value.length;
                for (let index = 0; index < length; index++) result.push(exported(value[index], seen));
            } else apply(setEach, value, [item => result.push(exported(item, seen))]);
            return result;
        }
        if (value instanceof mapType) {
            seen.set(value, value);
            apply(mapEach, value, [(item, key) => { exported(key, seen); exported(item, seen); }]);
            return value;
        }
        let stringObject;
        try { stringObject = apply(stringValue, value, []); } catch (_) {}
        const result = object.create(null);
        seen.set(value, result);
        for (const key of keys(value)) {
            if (stringObject !== undefined && /^(0|[1-9][0-9]*)$/.test(key) && Number(key) < stringObject.length) continue;
            result[key] = exported(value[key], seen);
        }
        return result;
    }
    function first(value, names) {
        for (const name of names) {
            const field = value[name];
            if (!empty(field)) return field;
        }
    }
    function text(value, names) {
        for (const name of names) {
            const field = exported(value[name]);
            if (typeof field === "string") return field.toWellFormed();
        }
        return "";
    }
    function int(value, names, wide = false) {
        const field = first(value, names);
        return empty(field) ? 0n : BigInt(host.providerInteger(+field, wide));
    }
    function map(value, names) {
        const field = exported(first(value, names));
        if (empty(field) || !helpers.isMap(field) || host.logOpaqueType(field) !== "") return null;
        const result = exportValue(field, []);
        return result !== null && typeof result === "object" && keys(result).length ? result : null;
    }
    function stringMap(value, names) {
        const field = first(value, names);
        if (empty(field)) return null;
        const result = object.create(null);
        for (const name of keys(object(field))) {
            const child = field[name];
            if (!empty(child)) result[name.toWellFormed()] = goString(child);
        }
        return keys(result).length ? result : null;
    }
    function strings(value, names) {
        const field = exported(first(value, names));
        if (!isArray(field) || host.logOpaqueType(field) !== "") return [];
        const result = [];
        for (const item of field) {
            const string = typeof item === "string" ? item.toWellFormed() : "";
            if (trim(string)) result.push(trim(string));
        }
        return result;
    }
    function fields(value, schema, required) {
        value = object(value);
        const result = object.create(null);
        for (const [name, kind, ...aliases] of schema) {
            const names = [name, ...aliases];
            let field;
            switch (kind) {
                case "s": field = text(value, names); break;
                case "i": field = int(value, names); break;
                case "l": field = int(value, names, true); break;
                case "b": field = Boolean(first(value, names)); break;
                case "m": field = map(value, names); break;
                case "M": field = stringMap(value, names); break;
                case "a": field = strings(value, names); break;
                default: throw Error("unknown provider field kind");
            }
            if (required.includes(name) || (field !== "" && field !== 0n && field !== false && field !== null && (!isArray(field) || field.length))) result[name] = field;
        }
        return result;
    }
    function array(value, parse) {
        if (empty(value)) return [];
        const lengthValue = object(value).length;
        if (empty(lengthValue)) throw Error("value is not an array");
        const length = Number(BigInt(host.providerInteger(+lengthValue, true)));
        if (length <= 0) return [];
        const count = Number(BigInt(host.providerInteger(length, false)));
        if (count < 0) throw Error("array length exceeds native integer range");
        const result = [];
        for (let index = 0; index < count; index++) {
            const item = value[index];
            if (!empty(item)) result.push(parse(item));
        }
        return result;
    }
    const trackSchema = [
        ["id","s"],["name","s"],["artists","s"],["album_name","s","albumName"],
        ["album_artist","s","albumArtist"],["album_id","s","albumId"],["album_url","s","albumUrl"],
        ["artist_id","s","artistId"],["artist_url","s","artistUrl"],
        ["external_urls","s","externalUrls","external_url","externalUrl","url"],
        ["duration_ms","i","durationMs"],["cover_url","s","coverUrl"],["preview_url","s","previewUrl"],
        ["images","s"],["release_date","s","releaseDate"],["track_number","i","trackNumber"],
        ["total_tracks","i","totalTracks"],["disc_number","i","discNumber"],["total_discs","i","totalDiscs"],
        ["isrc","s"],["provider_id","s","providerId"],["item_type","s","itemType"],
        ["album_type","s","albumType"],["explicit","b","is_explicit","isExplicit"],["upc","s","barcode"],
        ["tidal_id","s","tidalId"],["qobuz_id","s","qobuzId"],["deezer_id","s","deezerId"],
        ["spotify_id","s","spotifyId"],["external_links","M","externalLinks"],["label","s"],
        ["copyright","s"],["genre","s"],["composer","s"],["comment","s","comments"],
        ["audio_quality","s","audioQuality"],["audio_modes","s","audioModes"]
    ];
    const track = value => fields(value, trackSchema, ["id","name","artists","album_name","duration_ms","provider_id"]);
    function album(value) {
        const tracks = array(first(object(value), ["tracks"]), track);
        const result = fields(value, [
            ["id","s"],["name","s"],["artists","s"],["artist_id","s","artistId"],
            ["cover_url","s","coverUrl","images"],["header_image","s","headerImage"],
            ["header_video","s","headerVideo"],["release_date","s","releaseDate"],
            ["total_tracks","i","totalTracks"],["album_type","s","albumType"],
            ["audio_traits","a","audioTraits"],["provider_id","s","providerId"],
            ["editorial_notes","M","editorialNotes"],["description","s"]
        ], ["id","name","artists","total_tracks","provider_id"]);
        result.tracks = tracks;
        if (!trim(result.artists)) {
            const explicit = tracks.find(item => trim(item.album_artist || ""));
            if (explicit) result.artists = trim(explicit.album_artist);
            else {
                const counts = new Map();
                for (const item of tracks) {
                    const artist = trim(item.artists);
                    if (artist) counts.set(artist, (counts.get(artist) || 0) + 1);
                }
                let count = 0;
                result.artists = "";
                for (const [artist, votes] of counts) if (votes > count) { result.artists = artist; count = votes; }
            }
        }
        if (!trim(result.release_date || "")) {
            const source = tracks.find(item => trim(item.release_date || ""));
            if (source) result.release_date = trim(source.release_date);
            else delete result.release_date;
        }
        if (!result.audio_traits) {
            const traits = host.providerAudioTraits(tracks.map(item => item.audio_quality || ""), tracks.map(item => item.audio_modes || ""));
            if (traits.length) result.audio_traits = traits;
        }
        return result;
    }
    function artist(value) {
        const albums = array(first(object(value), ["albums"]), album);
        const releases = array(first(object(value), ["releases"]), album);
        const tracks = array(first(object(value), ["top_tracks","topTracks","tracks"]), track);
        const result = fields(value, [["id","s"],["name","s"],["image_url","s","imageUrl"],
            ["header_image","s","headerImage"],["header_video","s","headerVideo"],
            ["header_logo","s","headerLogo"],
            ["albums_next","s","albumsNext"],
            ["listeners","i"],["provider_id","s","providerId"]], ["id","name","provider_id"]);
        if (albums.length) result.albums = albums;
        if (releases.length) result.releases = releases;
        if (tracks.length) result.top_tracks = tracks;
        const concertItems = first(object(value), ["concerts"]);
        const concerts = isArray(concertItems) ? array(concertItems.slice(0, 500), concert) : [];
        if (concerts.length) result.concerts = concerts;
        return result;
    }
    function concert(value) {
        return fields(value, [["id","s"],["location","s"],["venue","s"],
            ["start_at","s","startAt"],["time_zone","s","timeZone"],
            ["url","s"],["detail_id","s","detailId"]], ["id","location","start_at"]);
    }
    function concertDetail(value) {
        const result = fields(value, [["id","s"],["artist_name","s","artistName"],
            ["title","s"],["cover_url","s","coverUrl"],["venue","s"],["address","s"],
            ["start_at","s","startAt"],["end_at","s","endAt"],["time_zone","s","timeZone"],
            ["ticket_url","s","ticketUrl"],["map_url","s","mapUrl"],["url","s"],
            ["attribution","s"]], ["id"]);
        const setList = first(object(value), ["set_list","setList"]);
        if (!empty(setList)) result.set_list = fields(setList, [["id","s"],["name","s"],
            ["cover_url","s","coverUrl"],["url","s"]], ["id","name"]);
        return result;
    }
    function decryption(value) {
        if (empty(value)) return null;
        const result = fields(value, [["strategy","s"],["key","s"],["iv","s"],
            ["input_format","s","inputFormat"],["output_extension","s","outputExtension"],["options","m"]], []);
        return keys(result).length ? result : null;
    }
    function download(value) {
        const result = fields(value, [
            ["success","b"],["file_path","s","filePath","path"],["already_exists","b","alreadyExists"],
            ["bit_depth","i","bitDepth"],["sample_rate","i","sampleRate"],["audio_codec","s","audioCodec","codec"],
            ["duration_ms","i","durationMs"],["error_message","s","errorMessage","error"],["error_type","s","errorType"],
            ["retry_after_seconds","i","retryAfterSeconds"],["title","s"],["artist","s"],["album","s"],
            ["album_artist","s","albumArtist"],["track_number","i","trackNumber"],["disc_number","i","discNumber"],
            ["total_tracks","i","totalTracks"],["total_discs","i","totalDiscs"],["release_date","s","releaseDate"],
            ["cover_url","s","coverUrl"],["isrc","s"],["genre","s"],["label","s"],["copyright","s"],
            ["composer","s"],["comment","s","comments"],["explicit","b","is_explicit","isExplicit"],
            ["album_type","s","albumType"],["upc","s","barcode"],["lyrics_lrc","s","lyricsLrc"],
            ["decryption_key","s","decryptionKey"]
        ], ["success"]);
        const info = decryption(first(object(value), ["decryption"]));
        if (info) result.decryption = info;
        object.assign(result, fields(value, [["actual_extension","s","actualExtension"],
            ["output_extension","s","outputExtension"],["actual_container","s","actualContainer","container"],
            ["requires_container_conversion","b","requiresContainerConversion"]], []));
        return result;
    }
    function url(value) {
        const result = fields(value, [["type","s"],["id","s"],["name","s"],["cover_url","s","coverUrl"],
            ["header_image","s","headerImage"],["header_video","s","headerVideo"]], ["type"]);
        value = object(value);
        for (const [name, parse] of [["track",track],["tracks",v => array(v,track)],["album",album],["artist",artist]]) {
            const field = first(value, [name]);
            if (!empty(field)) {
                const parsed = parse(field);
                if (!isArray(parsed) || parsed.length) result[name] = parsed;
            }
        }
        return result;
    }
    function lyrics(value) {
        const lines = array(first(object(value), ["lines"]), line => fields(line, [
            ["startTimeMs","l","start_time_ms"],["words","s"],["endTimeMs","l","end_time_ms"]
        ], ["startTimeMs","words","endTimeMs"]));
        const result = fields(value, [["syncType","s","sync_type"],["instrumental","b"],
            ["plainLyrics","s","plain_lyrics"],["provider","s"]], ["syncType","instrumental","plainLyrics","provider"]);
        result.lines = lines;
        return result;
    }
    function search(value) {
        const raw = first(object(value), ["tracks"]);
        const tracks = array(empty(raw) ? value : raw, track);
        const total = empty(raw) ? BigInt(tracks.length) : int(object(value), ["total"]);
        return {tracks, total: total || BigInt(tracks.length)};
    }
    function encode(value) {
        // BigInts here are native integer fields created by this parser. Opaque
        // extension maps pass through the existing Go export conversion first.
        if (typeof value === "bigint") return String(value);
        if (isArray(value)) return "[" + value.map(encode).join(",") + "]";
        if (value !== null && typeof value === "object") return "{" + keys(value).map(key => host.quoteJSON(key) + ":" + encode(value[key])).join(",") + "}";
        return serialize(value);
    }
    const parsers = {
        getTrack: track, enrichTrack: track, getAlbum: album, getPlaylist: album, getArtist: artist,
        getConcert: concertDetail,
        searchTracks: search, customSearch: value => array(value, track), handleUrl: url,
        getRelatedTracks: value => array(value, track),
        checkAvailability: value => fields(value, [["available","b"],["reason","s"],["track_id","s","trackId"],
            ["skip_fallback","b","skipFallback"],["prepared_context","m","preparedContext"]], ["available"]),
        download, fetchLyrics: lyrics,
        postProcessV2: value => fields(value, [["success","b"],["new_file_path","s","newFilePath"],
            ["new_file_uri","s","newFileUri"],["error","s"],["bit_depth","i","bitDepth"],["sample_rate","i","sampleRate"]], ["success"])
    };
    function invoke(method, args) {
        const extension = globalThis.extension;
        if (empty(extension)) return null;
        let name = method;
        if (method === "getPlaylist" && typeof extension.getPlaylist !== "function") name = "getAlbum";
        if (method === "postProcessV2" && typeof extension.postProcessV2 !== "function") {
            name = "postProcess";
            args = [args[0].path || "", args[1], args[2]];
        }
        const callback = extension[name];
        return typeof callback === "function" ? apply(callback, extension, args) : null;
    }
    function invokeVerified(method, args) {
        if (method === "getHomeFeed") {
            const extension = globalThis.extension;
            if (!empty(extension) && typeof extension[method] === "function") {
                return apply(extension[method], extension, args);
            }
            const callback = globalThis[method];
            return typeof callback === "function" ? apply(callback, globalThis, args) : null;
        }
        try { return invoke(method, args); }
        catch (error) {
            const id = method === "enrichTrack" ? null : host.providerPendingVerification();
            if (!empty(id) && !empty(error)) {
                let message;
                try {
                    const value = typeof error === "object" || typeof error === "function" ? error.message : error;
                    if (!empty(value)) message = trim(goString(value));
                } catch (_) {}
                if (message === "VERIFY_REQUIRED") {
                    throw "verification_required: extension '" + id + "' needs signed-session verification: " + goString(error);
                }
            }
            throw error;
        }
    }
    return {
        invoke: invokeVerified,
        invokeDownload(method, args) {
            const extension = globalThis.extension;
            if (empty(extension)) return null;
            const callback = extension[method];
            if (typeof callback !== "function") return null;
            const progress = function (value) {
                if (!arguments.length) return;
                const percent = BigInt(host.providerInteger(+value, false));
                host.providerProgress(Number(percent < 0n ? 0n : percent > 100n ? 100n : percent));
            };
            return apply(callback, extension, [args[0], args[1], args[2], progress, args[3]]);
        },
        invokePostProcess(method, args) {
            const result = {};
            try { result.value = invokeVerified(method, args); }
            catch (error) { result.failure = goString(error); }
            return result;
        },
        parsePostProcess(method, result) {
            let value;
            try {
                value = result.failure !== undefined ? {success:false,error:result.failure}
                    : empty(result.value) ? {success:false,error:"postProcess returned null"}
                    : parsers.postProcessV2(result.value);
            } catch (error) { value = {success:false,error:error.message || goString(error)}; }
            return "{\"value\":" + encode(value) + "}";
        },
        parse(method, value) {
            if (empty(value)) return "{\"value\":null}";
            if (method === "getHomeFeed") {
                // The Go export marshals goja.Value directly: JSON.stringify,
                // including toJSON/undefined semantics, without awaiting Promises.
                try { return "{\"value\":" + (stringify(value) || "null") + "}"; }
                catch (error) { return serialize({parseError: error.message || goString(error)}); }
            }
            try { return "{\"value\":" + encode(parsers[method](value)) + "}"; }
            catch (error) { return serialize({parseError: error.message || goString(error)}); }
        }
    };
})
