package com.zarz.mornye

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeFinalizationPolicyTest {
    @Test
    fun metadataCoverUsesEnrichedResultBeforeTheOriginalThumbnail() {
        val fullSize = "https://example.test/cover/3000.jpg"
        val thumbnail = "https://example.test/cover/300.jpg"
        assertEquals(fullSize, NativeFinalizationPolicy.metadataCoverUrl(fullSize, thumbnail, thumbnail))
        assertEquals(fullSize, NativeFinalizationPolicy.metadataCoverUrl("", fullSize, thumbnail))
        assertEquals(thumbnail, NativeFinalizationPolicy.metadataCoverUrl(null, "null", thumbnail))
        assertEquals("", NativeFinalizationPolicy.metadataCoverUrl(null, " ", null))
    }

    @Test
    fun metadataSeparatorsPreserveNamesAndSourceDefaults() {
        assertEquals("A; B; C", NativeFinalizationPolicy.metadataTagValue(" A, B ; C ", "; "))
        assertEquals(" A, B ", NativeFinalizationPolicy.metadataTagValue(" A, B ", ""))
        for (name in listOf("AC/DC", "R&B", "Florence and the Machine", "Simon & Garfunkel", "Malcolm X")) {
            assertEquals(name, NativeFinalizationPolicy.metadataTagValue(name, " / "))
        }
        for (invalid in listOf("\n", "\u0000", "abcdefghijklmnopq")) {
            assertEquals("A, B", NativeFinalizationPolicy.metadataTagValue("A, B", invalid))
        }
    }

    // Shared with the Rust and Dart primary-artist tests; keep in sync.
    @Test
    fun primaryArtistModeKeepsTheFirstCreditedArtist() {
        for ((input, expected) in listOf(
            "Calle 24, Chino Pacas" to "Calle 24",
            "Calle 24 & Chino Pacas" to "Calle 24",
            "Artist A; Artist B" to "Artist A",
            "Artist A feat. Artist B" to "Artist A",
            "Artist A Feat Artist B" to "Artist A",
            "Artist A ft. Artist B" to "Artist A",
            "Artist A featuring Artist B" to "Artist A",
            "Artist A featured Artist B" to "Artist A",
            "Artist A feature Artist B" to "Artist A",
            "Artist A with Artist B" to "Artist A",
            "Artist A x Artist B" to "Artist A",
            "Artist A X Artist B" to "Artist A",
            "Artist A\u00A0feat.\u00A0Artist B" to "Artist A",
            "Artist A\u3000x\u3000Artist B" to "Artist A",
            " , Artist A, Artist B" to "Artist A",
            "Malcolm X" to "Malcolm X",
            "Artist Without Fear" to "Artist Without Fear",
            "Maxx" to "Maxx",
            "AC/DC" to "AC/DC",
            "  Various Artists  " to "Various Artists",
            "" to "",
        )) {
            assertEquals(input, expected, NativeFinalizationPolicy.artistTagValue(input, " Primary "))
        }
        // Joined and split values are left to the backend writer unchanged.
        for (mode in listOf("joined", "split_vorbis", "", null)) {
            assertEquals(
                "Artist A, Artist B",
                NativeFinalizationPolicy.artistTagValue("Artist A, Artist B", mode),
            )
        }
    }

    @Test
    fun durationUsesDeclaredUnitsForShortTracksAndLongPerformances() {
        assertEquals(250L, NativeFinalizationPolicy.durationMilliseconds(250, 0))
        assertEquals(8000L, NativeFinalizationPolicy.durationMilliseconds(8000, 8))
        assertEquals(10000L, NativeFinalizationPolicy.durationMilliseconds(10000, 10))
        assertEquals(180000L, NativeFinalizationPolicy.durationMilliseconds(180000, 0))
        assertEquals(8000L, NativeFinalizationPolicy.durationMilliseconds(0, 8))
        assertEquals(14400000L, NativeFinalizationPolicy.durationMilliseconds(0, 14400))
        assertEquals(0L, NativeFinalizationPolicy.durationMilliseconds(0, -1))
    }

    @Test
    fun matchesSharedContainerConversionCases() {
        val stream = checkNotNull(javaClass.getResourceAsStream("/finalization_container_cases.tsv"))
        stream.bufferedReader().useLines { lines ->
            for (line in lines) {
                if (line.isBlank() || line.startsWith("#")) continue
                val fields = line.split('\t')
                assertEquals("invalid shared fixture: $line", 3, fields.size)
                assertEquals(
                    line,
                    fields[2].toBooleanStrict(),
                    NativeFinalizationPolicy.shouldAttemptLosslessContainerConversion(
                        forceConversion = fields[0].toBooleanStrict(),
                        probedCodec = fields[1],
                    ),
                )
            }
        }
    }

    @Test
    fun lateAlbumMetadataResolvesOnlyThePendingFolderLeaf() {
        assertEquals(
            "Playlist/Artist/[2024] Album",
            NativeFinalizationPolicy.resolvedAlbumRelativeDirectory(
                "Playlist/Artist/[2024] Unknown", "[2024] {album}", "[2024] Album",
            ),
        )
        assertEquals(
            "Album",
            NativeFinalizationPolicy.resolvedAlbumRelativeDirectory("Unknown", "{album}", "Album"),
        )
        for (album in listOf("", "..", "../Album", "Album/Part", "Album\\Part")) {
            assertEquals(
                "Artist/Unknown",
                NativeFinalizationPolicy.resolvedAlbumRelativeDirectory("Artist/Unknown", "{album}", album),
            )
        }
        assertEquals(
            "Unknown",
            NativeFinalizationPolicy.resolvedAlbumRelativeDirectory("Unknown", "", "Album"),
        )
    }

    @Test
    fun matchesSharedLyricUsabilityCases() {
        val stream = checkNotNull(
            javaClass.getResourceAsStream("/lyrics_usability_cases.tsv"),
        )
        stream.bufferedReader().useLines { lines ->
            for (line in lines) {
                if (line.isBlank() || line.startsWith("#")) continue
                val fields = line.split('\t')
                assertEquals("invalid shared fixture: $line", 3, fields.size)
                val lyrics = fields[2]
                    .replace("\\n", "\n")
                    .replace("\\r", "\r")
                    .replace("\\t", "\t")
                assertEquals(
                    fields[0],
                    fields[1].toBooleanStrict(),
                    NativeFinalizationPolicy.hasUsableLyricsContent(lyrics),
                )
            }
        }
    }

    @Test
    fun usableLyricsRejectsHeadersButKeepsRealAndInstrumentalContent() {
        assertFalse(
            NativeFinalizationPolicy.hasUsableLyricsContent(
                "[ar:Artist]\n[ti:Title]\n[offset:0]",
            ),
        )
        assertFalse(
            NativeFinalizationPolicy.hasUsableLyricsContent(
                "[00:01.00]\n<00:01.10>\nv1:",
            ),
        )
        assertTrue(
            NativeFinalizationPolicy.hasUsableLyricsContent(
                "[00:01.00]<00:01.10>v1: First line",
            ),
        )
        assertTrue(
            NativeFinalizationPolicy.hasUsableLyricsContent("[bg:Backing vocal]"),
        )
        assertTrue(
            NativeFinalizationPolicy.hasUsableLyricsContent("[instrumental:true]"),
        )
    }

    @Test
    fun downloadLyricsFallBackWhenProviderContentContainsNoLyrics() {
        for (supplied in listOf(null, "", "  ", "[ar:Artist]\n[ti:Title]", "[00:01.00]\n<00:01.10>\nv1:")) {
            var calls = 0
            val resolved = NativeFinalizationPolicy.resolveLyricsContent(supplied) {
                calls++
                "  [00:01.00]Recovered lyric  "
            }
            assertEquals(1, calls)
            assertEquals("[00:01.00]Recovered lyric", resolved)
        }
    }

    @Test
    fun downloadLyricsReuseRealLyricsAndInstrumentalMarkersWithoutFetching() {
        for (supplied in listOf("[00:01.00]Existing lyric", "Plain lyric", "[instrumental:true]")) {
            assertEquals(
                supplied,
                NativeFinalizationPolicy.resolveLyricsContent("  $supplied  ") {
                    error("Usable provider content must not trigger another lookup")
                },
            )
        }
    }

    @Test
    fun downloadLyricsRejectUnusableFallbackContent() {
        for (fetched in listOf("", "[ar:Artist]\n[ti:Title]", "[00:01.00]")) {
            assertEquals("", NativeFinalizationPolicy.resolveLyricsContent(null) { fetched })
        }
    }

    @Test
    fun automaticConversionSettingsAreNormalizedAndComparable() {
        val target = checkNotNull(
            NativeFinalizationPolicy.autoConversionTarget(
                enabled = true,
                format = "M4A",
                bitrate = "256 kbps",
            ),
        )
        assertEquals("aac", target.codec)
        assertEquals(".m4a", target.extension)
        assertEquals(256, target.bitrateKbps)
        assertEquals(160, NativeFinalizationPolicy.autoConversionTarget(true, "opus", "160k")?.bitrateKbps)
        assertTrue(
            NativeFinalizationPolicy.autoConversionAlreadySatisfied(
                target,
                audioCodec = "mp4a",
                bitrateKbps = 256,
            ),
        )
        assertFalse(
            NativeFinalizationPolicy.autoConversionAlreadySatisfied(
                target,
                audioCodec = "aac",
                bitrateKbps = 128,
            ),
        )
        assertNull(
            NativeFinalizationPolicy.autoConversionTarget(
                enabled = false,
                format = "opus",
                bitrate = "128k",
            ),
        )
    }

    @Test
    fun flacAutomaticConversionCapsQualityWithoutUpsampling() {
        val target = checkNotNull(NativeFinalizationPolicy.autoConversionTarget(true, "flac", ""))
        assertEquals(16, target.maxBitDepth)
        assertEquals(48000, target.maxSampleRate)
        assertEquals(".flac", target.extension)
        assertTrue(NativeFinalizationPolicy.autoConversionAlreadySatisfied(target, "flac", null, 16, 44100))
        assertFalse(NativeFinalizationPolicy.autoConversionAlreadySatisfied(target, "flac", null, 24, 96000))
        assertFalse(NativeFinalizationPolicy.autoConversionAlreadySatisfied(target, "flac", null))
        assertFalse(NativeFinalizationPolicy.autoConversionAlreadySatisfied(target, "aac", null, 16, 44100))

        val highResolution = NativeFinalizationPolicy.flacAutoConversionArguments(target, "in.flac", "out.flac", 24, 96000)
        assertTrue(highResolution.contains("aresample=resampler=swr:osr=48000:osf=s16"))
        val lowerRate = NativeFinalizationPolicy.flacAutoConversionArguments(target, "in.flac", "out.flac", 24, 44100)
        assertTrue(lowerRate.contains("aresample=resampler=swr:osf=s16"))
        assertFalse(lowerRate.any { it.contains("osr=") })
        val original = checkNotNull(NativeFinalizationPolicy.autoConversionTarget(true, "flac", "", 0, 0))
        assertTrue(NativeFinalizationPolicy.autoConversionAlreadySatisfied(original, "flac", null, 24, 96000))
    }

    @Test
    fun matchesSharedCrossPipelineQualityCases() {
        val stream = checkNotNull(
            javaClass.getResourceAsStream("/finalization_quality_cases.tsv"),
        )
        stream.bufferedReader().useLines { lines ->
            for (line in lines) {
                if (line.isBlank() || line.startsWith("#")) continue
                val fields = line.split('\t')
                assertEquals("invalid shared fixture: $line", 6, fields.size)
                val actual = NativeFinalizationPolicy.qualityVariantFilenameLabel(
                    measuredQuality = fields[4],
                    bitDepth = fields[1].toIntOrNull(),
                    sampleRate = fields[2].toIntOrNull(),
                    bitrateKbps = fields[3].toIntOrNull(),
                    audioCodec = fields[0],
                )
                val expected = fields[5].takeUnless { it == "<null>" }
                assertEquals("shared fixture: $line", expected, actual)
            }
        }
    }

    @Test
    fun codecAliasesDriveLossyAndLosslessDecisions() {
        assertEquals("aac", NativeFinalizationPolicy.normalizeAudioCodec("mp4a"))
        assertEquals("eac3", NativeFinalizationPolicy.normalizeAudioCodec("ec-3"))
        assertEquals("opus", NativeFinalizationPolicy.normalizeAudioCodec("ogg"))
        assertTrue(NativeFinalizationPolicy.isLossyAudioCodec("ac-4"))
        assertTrue(NativeFinalizationPolicy.isLosslessAudioCodec("pcm_s24le"))
        assertTrue(NativeFinalizationPolicy.isLosslessAudioCodec("ALAC"))
        assertFalse(NativeFinalizationPolicy.isLosslessAudioCodec("aac"))
    }

    @Test
    fun forcedContainerConversionAttemptsInconclusiveCodecButPreservesLossy() {
        assertTrue(
            NativeFinalizationPolicy.shouldAttemptLosslessContainerConversion(
                forceConversion = true,
                probedCodec = null,
            ),
        )
        assertTrue(
            NativeFinalizationPolicy.shouldAttemptLosslessContainerConversion(
                forceConversion = true,
                probedCodec = "m4a",
            ),
        )
        assertTrue(
            NativeFinalizationPolicy.shouldAttemptLosslessContainerConversion(
                forceConversion = false,
                probedCodec = "flac",
            ),
        )
        assertFalse(
            NativeFinalizationPolicy.shouldAttemptLosslessContainerConversion(
                forceConversion = true,
                probedCodec = "aac",
            ),
        )
        assertFalse(
            NativeFinalizationPolicy.shouldAttemptLosslessContainerConversion(
                forceConversion = false,
                probedCodec = null,
            ),
        )
    }

    @Test
    fun isoBmffAudioUsesM4aExceptForAc4Passthrough() {
        assertEquals(
            ".m4a",
            NativeFinalizationPolicy.isoBmffAudioExtension("opus"),
        )
        assertEquals(
            ".m4a",
            NativeFinalizationPolicy.isoBmffAudioExtension("ec-3"),
        )
        assertEquals(
            ".m4a",
            NativeFinalizationPolicy.isoBmffAudioExtension("aac"),
        )
        assertEquals(
            ".mp4",
            NativeFinalizationPolicy.isoBmffAudioExtension("ac-4"),
        )
    }

    @Test
    fun normalizedRequestAlbumArtistOverridesPerTrackProviderCredits() {
        assertEquals(
            "Falling In Reverse",
            NativeFinalizationPolicy.authoritativeAlbumArtist(
                requestValue = "Falling In Reverse",
                trackValue = "Falling In Reverse, Jelly Roll",
                providerResultValue = "Falling In Reverse, Jelly Roll",
            ),
        )
        assertEquals(
            "Provider Album Artist",
            NativeFinalizationPolicy.authoritativeAlbumArtist(
                requestValue = "",
                trackValue = null,
                providerResultValue = "Provider Album Artist",
            ),
        )
    }

    @Test
    fun displayQualityUsesMeasuredLosslessSpecifications() {
        assertEquals(
            "24-bit/96kHz",
            NativeFinalizationPolicy.displayAudioQuality(
                filePath = "/music/track.flac",
                fileName = "track.flac",
                bitDepth = 24,
                sampleRate = 96000,
                bitrateKbps = null,
                audioCodec = "flac",
                storedQuality = "HI_RES",
            ),
        )
        assertEquals(
            "24-bit/44.1kHz",
            NativeFinalizationPolicy.displayAudioQuality(
                filePath = "/music/track.flac",
                fileName = "track.flac",
                bitDepth = 24,
                sampleRate = 44100,
                bitrateKbps = null,
                audioCodec = "flac",
                storedQuality = "LOSSLESS",
            ),
        )
    }

    @Test
    fun displayQualityPreservesUsefulLossyLabels() {
        assertEquals(
            "OPUS 192kbps",
            NativeFinalizationPolicy.displayAudioQuality(
                filePath = "/music/track.ogg",
                fileName = "track.ogg",
                bitDepth = null,
                sampleRate = 48000,
                bitrateKbps = 192,
                audioCodec = "opus",
                storedQuality = "HIGH",
            ),
        )
        assertEquals(
            "AAC",
            NativeFinalizationPolicy.displayAudioQuality(
                filePath = "/music/track.m4a",
                fileName = "track.m4a",
                bitDepth = null,
                sampleRate = 48000,
                bitrateKbps = null,
                audioCodec = "aac",
                storedQuality = "LOSSLESS",
            ),
        )
    }

    @Test
    fun qualityVariantLabelRejectsUnmeasuredPlaceholders() {
        assertNull(
            NativeFinalizationPolicy.qualityVariantFilenameLabel(
                measuredQuality = "LOSSLESS",
                bitDepth = null,
                sampleRate = null,
                bitrateKbps = null,
                audioCodec = "flac",
            ),
        )
        assertEquals(
            "24bit-96kHz",
            NativeFinalizationPolicy.qualityVariantFilenameLabel(
                measuredQuality = "24-bit/96kHz",
                bitDepth = null,
                sampleRate = null,
                bitrateKbps = null,
                audioCodec = "flac",
            ),
        )
        assertEquals(
            "320kbps",
            NativeFinalizationPolicy.qualityVariantFilenameLabel(
                measuredQuality = "MP3 320kbps",
                bitDepth = null,
                sampleRate = null,
                bitrateKbps = null,
                audioCodec = "mp3",
            ),
        )
    }

    @Test
    fun finalQualityLabelReplacesOnlyTheStagingToken() {
        assertEquals(
            "Artist - Track - 24bit-96kHz.flac",
            NativeFinalizationPolicy.applyQualityVariantFilenameLabel(
                fileName = "Artist - Track - pending.flac",
                stagingLabel = "pending",
                qualityLabel = "24bit-96kHz",
            ),
        )
        assertEquals(
            "Artist - Track - 24bit-96kHz.flac",
            NativeFinalizationPolicy.applyQualityVariantFilenameLabel(
                fileName = "Artist - Track.flac",
                stagingLabel = "",
                qualityLabel = "24bit-96kHz",
            ),
        )
    }

    @Test
    fun measuredQualityIsAddedOnlyAfterCleanNameCollision() {
        val stagedName = "Artist - Track - qv_ab12cd34.flac"
        assertEquals(
            "Artist - Track.flac",
            NativeFinalizationPolicy.removeQualityVariantStagingLabel(
                fileName = stagedName,
                stagingLabel = "qv_ab12cd34",
            ),
        )
        assertEquals(
            "Artist - Track.flac",
            NativeFinalizationPolicy.resolveQualityVariantFilename(
                fileName = stagedName,
                stagingLabel = "qv_ab12cd34",
                qualityLabel = "24bit-96kHz",
                collisionOnly = true,
                cleanNameExists = false,
            ),
        )
        assertEquals(
            "Artist - Track - 24bit-96kHz.flac",
            NativeFinalizationPolicy.resolveQualityVariantFilename(
                fileName = stagedName,
                stagingLabel = "qv_ab12cd34",
                qualityLabel = "24bit-96kHz",
                collisionOnly = true,
                cleanNameExists = true,
            ),
        )
    }

    @Test
    fun deferredSafNamingNeverPublishesTheNativeCacheName() {
        val logicalName = NativeFinalizationPolicy.logicalOutputFileName(
            deferredSafPublish = true,
            resultSafFileName = "Sunidhi Chauhan - Aisa Jadoo - qv_ab12cd34.flac",
            requestSafFileName = "fallback.flac",
            currentFileName = "native_saf_work_603020549715656640.m4a",
        )

        assertEquals(
            "Sunidhi Chauhan - Aisa Jadoo - 16bit-44.1kHz.flac",
            NativeFinalizationPolicy.applyQualityVariantFilenameLabel(
                fileName = logicalName,
                stagingLabel = "qv_ab12cd34",
                qualityLabel = "16bit-44.1kHz",
            ),
        )
    }

    @Test
    fun nonSafNamingStillFollowsTheCurrentConvertedFile() {
        assertEquals(
            "converted.flac",
            NativeFinalizationPolicy.logicalOutputFileName(
                deferredSafPublish = false,
                resultSafFileName = "ignored.flac",
                requestSafFileName = "ignored-too.flac",
                currentFileName = "converted.flac",
            ),
        )
    }

    @Test
    fun decryptionExtensionAndIndexTagsHaveStableFallbacks() {
        assertEquals(
            ".m4a",
            NativeFinalizationPolicy.resolvePreferredDecryptionExtension(
                inputPath = "/music/encrypted.bin",
                requested = "M4A",
            ),
        )
        assertEquals(
            ".flac",
            NativeFinalizationPolicy.resolvePreferredDecryptionExtension(
                inputPath = "/music/encrypted.m4a",
                requested = "",
            ),
        )
        assertEquals("3/12", NativeFinalizationPolicy.formatIndexTag(3, 12))
        assertEquals("3", NativeFinalizationPolicy.formatIndexTag(3, 0))
        assertEquals("0", NativeFinalizationPolicy.formatIndexTag(0, 12))
    }
}
