import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mornye/services/audio_metadata_mapper.dart';
import 'package:mornye/services/ffmpeg_models.dart';
import 'package:mornye/services/ffmpeg_support.dart';
import 'package:mornye/services/id3v23_lyrics.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/artist_utils.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('FFmpeg');

/// Container-specific metadata and artwork operations, independent of encoding.
abstract final class FFmpegMetadata {
  @visibleForTesting
  static List<String> buildCoverResizeArguments({
    required String inputPath,
    required String outputPath,
    required int maxDimension,
  }) {
    if (maxDimension < 64 || maxDimension > 8192) {
      throw ArgumentError.value(
        maxDimension,
        'maxDimension',
        'Must be between 64 and 8192 pixels',
      );
    }
    return [
      '-y',
      '-i',
      inputPath,
      '-map_metadata',
      '-1',
      '-an',
      '-sn',
      '-vf',
      'scale=$maxDimension:$maxDimension:'
          'force_original_aspect_ratio=decrease:flags=lanczos',
      '-frames:v',
      '1',
      '-update',
      '1',
      '-q:v',
      '2',
      outputPath,
    ];
  }

  static Future<bool> resizeCoverArt({
    required String inputPath,
    required String outputPath,
    required int maxDimension,
  }) async {
    try {
      if (!await File(inputPath).exists()) return false;
      final result = await FFmpegExecution.arguments(
        buildCoverResizeArguments(
          inputPath: inputPath,
          outputPath: outputPath,
          maxDimension: maxDimension,
        ),
      );
      final output = File(outputPath);
      if (result.success &&
          await output.exists() &&
          await output.length() > 0) {
        return true;
      }
      _log.w(
        'Cover resize failed (${result.returnCode}): '
        '${FFmpegExecution.preview(result.output)}',
      );
    } catch (e) {
      _log.w('Cover resize failed: $e');
    }
    await FFmpegOutput.cleanup(outputPath);
    return false;
  }

  static void appendCoverInputArguments(
    List<String> arguments, {
    String map = '1:v',
    String disposition = '-disposition:v:0',
  }) => arguments.addAll([
    '-map',
    map,
    '-c:v',
    'copy',
    disposition,
    'attached_pic',
    '-metadata:s:v',
    'title=Album cover',
    '-metadata:s:v',
    'comment=Cover (front)',
  ]);

  static Future<String?> _finish(
    FFmpegResult result,
    String tempOutput,
    String path,
    String format,
  ) async {
    if (result.success) {
      final promoted = await FFmpegOutput.promote(
        tempOutput,
        path,
        onMissing: () =>
            _log.e('Temp $format output file not found: $tempOutput'),
        onError: (e) =>
            _log.e('Failed to replace $format file after metadata embed: $e'),
      );
      if (!promoted) return null;
      _log.d('$format metadata embedded successfully');
      return path;
    }
    await FFmpegOutput.cleanup(tempOutput);
    _log.e('$format Metadata/Cover embed failed: ${result.output}');
    return null;
  }

  static Future<String?> embedMetadata({
    required String flacPath,
    String? coverPath,
    Map<String, String>? metadata,
    String artistTagMode = artistTagModeJoined,
  }) async {
    final tempOutput = await FFmpegOutput.tempPath('.flac');
    final arguments = <String>['-v', 'error', '-hide_banner', '-i', flacPath];
    if (coverPath != null) arguments.addAll(['-i', coverPath]);
    arguments.addAll(['-map', '0:a']);
    if (coverPath != null) {
      appendCoverInputArguments(
        arguments,
        map: '1:0',
        disposition: '-disposition:v',
      );
    }
    arguments.addAll(['-c:a', 'copy']);
    if (metadata != null) {
      AudioMetadataMapper.appendVorbisMetadataArguments(
        arguments,
        metadata,
        artistTagMode: artistTagMode,
      );
    }
    arguments.addAll([tempOutput, '-y']);
    _log.d('Executing FFmpeg FLAC embed command');
    return _finish(
      await FFmpegExecution.arguments(arguments),
      tempOutput,
      flacPath,
      'FLAC',
    );
  }

  static Future<String?> embedMetadataToMp3({
    required String mp3Path,
    String? coverPath,
    Map<String, String>? metadata,
    String artistTagMode = artistTagModeJoined,
    bool preserveMetadata = false,
  }) async {
    // ID3 keeps one artist frame: only primary mode changes its value.
    if (metadata != null) {
      metadata = applyArtistTagModeToMetadata(metadata, artistTagMode);
    }
    var tempOutput = await FFmpegOutput.tempPath('.mp3');
    final lyrics = AudioMetadataMapper.extractLyricsForId3(metadata);
    var result = await _runMp3Embed(
      mp3Path: mp3Path,
      tempOutput: tempOutput,
      coverPath: coverPath,
      metadata: metadata,
      preserveMetadata: preserveMetadata,
      audioCodec: 'copy',
    );
    if (!result.success &&
        (result.output.contains('Invalid audio stream') ||
            result.output.contains('incorrect codec parameters'))) {
      _log.w('MP3 copy failed (codec mismatch), re-encoding with libmp3lame');
      await FFmpegOutput.cleanup(tempOutput);
      tempOutput = await FFmpegOutput.tempPath('.mp3');
      result = await _runMp3Embed(
        mp3Path: mp3Path,
        tempOutput: tempOutput,
        coverPath: coverPath,
        metadata: metadata,
        preserveMetadata: preserveMetadata,
        audioCodec: 'libmp3lame',
        audioBitrate: '192k',
      );
    }
    final embeddedPath = await _finish(result, tempOutput, mp3Path, 'MP3');
    if (embeddedPath != null && lyrics != null) {
      await _ensureMp3UnsyncedLyricsFrame(embeddedPath, lyrics);
    }
    return embeddedPath;
  }

  static Future<FFmpegResult> _runMp3Embed({
    required String mp3Path,
    required String tempOutput,
    String? coverPath,
    Map<String, String>? metadata,
    required bool preserveMetadata,
    required String audioCodec,
    String? audioBitrate,
  }) async {
    final arguments = <String>['-v', 'error', '-hide_banner', '-i', mp3Path];
    if (coverPath != null) arguments.addAll(['-i', coverPath]);
    arguments.addAll([
      '-map',
      '0:a',
      '-map_metadata',
      preserveMetadata ? '0' : '-1',
    ]);
    if (coverPath != null) {
      arguments.addAll([
        '-map',
        '1:0',
        '-c:v:0',
        'copy',
        '-id3v2_version',
        '3',
        '-metadata:s:v',
        'title=Album cover',
        '-metadata:s:v',
        'comment=Cover (front)',
      ]);
    } else if (preserveMetadata) {
      arguments.addAll(['-map', '0:v?', '-c:v', 'copy']);
    }
    arguments.addAll(['-c:a', audioCodec]);
    if (audioBitrate != null) arguments.addAll(['-b:a', audioBitrate]);
    if (metadata != null) {
      AudioMetadataMapper.appendMappedMetadataArguments(
        arguments,
        AudioMetadataMapper.convertToId3Tags(metadata),
      );
    }
    arguments.addAll(['-id3v2_version', '3', tempOutput, '-y']);
    _log.d('Executing FFmpeg MP3 embed command (codec: $audioCodec)');
    return FFmpegExecution.arguments(arguments);
  }

  static Future<void> _ensureMp3UnsyncedLyricsFrame(
    String path,
    String lyrics,
  ) async {
    try {
      final file = File(path);
      if (!await file.exists()) return;
      if (!await Id3v23Lyrics.writeUnsyncedLyricsToFile(file, lyrics)) {
        _log.w('Skipping MP3 USLT lyrics frame update: unsupported ID3 tag');
        return;
      }
      _log.d('MP3 USLT lyrics frame written (${lyrics.length} chars)');
    } catch (e) {
      _log.w('Failed to write MP3 USLT lyrics frame: $e');
    }
  }

  static Future<String?> embedMetadataToOpus({
    required String opusPath,
    String? coverPath,
    Map<String, String>? metadata,
    String artistTagMode = artistTagModeJoined,
    bool preserveMetadata = false,
    @visibleForTesting Future<FFmpegResult> Function(List<String>)? execute,
  }) async {
    final tempOutput = await FFmpegOutput.tempPath('.opus');
    try {
      final arguments = <String>['-v', 'error', '-hide_banner', '-i', opusPath];
      // Opus tags are on the audio stream. Copy to output globals, override the
      // selected values and let the muxer write globals into the output stream.
      arguments.addAll([
        '-map',
        '0:a',
        '-map_metadata',
        preserveMetadata ? '0:s:a:0' : '-1',
        '-map_metadata:s:a',
        '-1',
        '-c:a',
        'copy',
      ]);
      if (metadata != null) {
        AudioMetadataMapper.appendVorbisMetadataArguments(
          arguments,
          metadata,
          artistTagMode: artistTagMode,
        );
      }
      if (coverPath != null) {
        final pictureBlock = await _createMetadataBlockPicture(coverPath);
        if (pictureBlock != null) {
          // The shared executor moves large tag values to a metadata file.
          arguments.addAll([
            '-metadata',
            'METADATA_BLOCK_PICTURE=$pictureBlock',
          ]);
          _log.d(
            'Created METADATA_BLOCK_PICTURE for Opus (${pictureBlock.length} chars)',
          );
        } else {
          _log.w('Failed to create METADATA_BLOCK_PICTURE, skipping cover');
        }
      }
      arguments.addAll([tempOutput, '-y']);
      _log.d('Executing FFmpeg Opus embed command');
      return await _finish(
        await FFmpegExecution.arguments(arguments, execute: execute),
        tempOutput,
        opusPath,
        'Opus',
      );
    } finally {
      await FFmpegOutput.cleanup(tempOutput);
    }
  }

  static Future<String?> embedMetadataToM4a({
    required String m4aPath,
    String? coverPath,
    Map<String, String>? metadata,
    String artistTagMode = artistTagModeJoined,
    bool preserveMetadata = true,
    @visibleForTesting Future<FFmpegResult> Function(List<String>)? execute,
  }) async {
    if (metadata != null) {
      metadata = applyArtistTagModeToMetadata(metadata, artistTagMode);
    }
    final tempOutput = await FFmpegOutput.tempPath('.m4a');
    final normalizedCoverPath = coverPath?.trim();
    final hasCover =
        normalizedCoverPath != null &&
        normalizedCoverPath.isNotEmpty &&
        await File(normalizedCoverPath).exists();
    final preserveExistingStreams = preserveMetadata && !hasCover;
    List<String> buildArgs(bool forceMov) {
      final arguments = <String>['-v', 'error', '-hide_banner', '-i', m4aPath];
      if (hasCover) arguments.addAll(['-i', normalizedCoverPath]);
      // Preserve attached artwork when no replacement cover is supplied.
      arguments.addAll(
        preserveExistingStreams
            ? ['-map', '0', '-c', 'copy']
            : ['-map', '0:a', '-c:a', 'copy'],
      );
      arguments.addAll(['-map_metadata', preserveMetadata ? '0' : '-1']);
      if (hasCover) appendCoverInputArguments(arguments);
      if (metadata != null) {
        AudioMetadataMapper.appendMappedMetadataArguments(
          arguments,
          AudioMetadataMapper.convertToM4aTags(metadata),
        );
      }
      // The default .m4a (ipod) muxer rejects FLAC. MP4 supports FLAC and
      // writes artwork as covr atoms, including artwork copied from the input.
      if (forceMov) {
        arguments.addAll(['-f', 'mov']);
      } else {
        // Older FFmpeg builds require experimental compliance for FLAC in MP4.
        arguments.addAll(['-f', 'mp4', '-strict', 'experimental']);
      }
      return arguments..addAll([tempOutput, '-y']);
    }

    _log.d('Executing FFmpeg M4A embed command');
    Future<FFmpegResult> run(List<String> arguments) =>
        FFmpegExecution.arguments(arguments, execute: execute);
    var result = await run(buildArgs(false));
    // MOV supports some codecs MP4 rejects (for example AC-4). Other
    // failures must retain their original error instead of trying MOV,
    // which cannot carry FLAC even with experimental compliance enabled.
    if (!result.success &&
        result.output.contains('codec not currently supported in container')) {
      _log.w(
        'M4A embed codec rejected by MP4, retrying with mov muxer: '
        '${FFmpegExecution.preview(result.output)}',
      );
      await FFmpegOutput.cleanup(tempOutput);
      result = await run(buildArgs(true));
    }
    final embedded = await _finish(result, tempOutput, m4aPath, 'M4A');
    if (embedded != null && metadata != null) {
      await writeM4AFreeformTags(m4aPath, metadata);
      await writeM4AReleaseIdentityTags(m4aPath, metadata);
    }
    return embedded;
  }

  static Future<String?> _createMetadataBlockPicture(String imagePath) async {
    try {
      final result = await PlatformBridge.runNativeDataJob({
        'operation': 'build_metadata_picture',
        'file_path': imagePath,
      });
      return result['picture'] as String?;
    } on MissingPluginException {
      return Isolate.run(
        () => _createMetadataBlockPictureInBackground(imagePath),
      );
    } catch (e) {
      _log.e('Error creating METADATA_BLOCK_PICTURE: $e');
      return null;
    }
  }

  static Future<String?> _createMetadataBlockPictureInBackground(
    String imagePath,
  ) async {
    try {
      final file = File(imagePath);
      if (!await file.exists()) {
        _log.e('Cover image not found: $imagePath');
        return null;
      }
      final data = await file.readAsBytes();
      final path = imagePath.toLowerCase();
      final pngSignature =
          data.length >= 8 &&
          data[0] == 0x89 &&
          data[1] == 0x50 &&
          data[2] == 0x4e &&
          data[3] == 0x47;
      final mime =
          path.endsWith('.png') ||
              (!path.endsWith('.jpg') &&
                  !path.endsWith('.jpeg') &&
                  pngSignature)
          ? 'image/png'
          : 'image/jpeg';
      final mimeBytes = utf8.encode(mime);
      // One allocation: type, MIME length/string, empty description, four zero
      // image properties, payload length and the original image bytes.
      final buffer = ByteData(32 + mimeBytes.length + data.length);
      final bytes = buffer.buffer.asUint8List();
      buffer.setUint32(0, 3, Endian.big);
      buffer.setUint32(4, mimeBytes.length, Endian.big);
      bytes.setRange(8, 8 + mimeBytes.length, mimeBytes);
      buffer.setUint32(28 + mimeBytes.length, data.length, Endian.big);
      bytes.setRange(32 + mimeBytes.length, bytes.length, data);
      return base64Encode(bytes);
    } catch (e) {
      _log.e('Error creating METADATA_BLOCK_PICTURE: $e');
      return null;
    }
  }

  static Future<bool> embedChunkTagsNative(
    String path,
    Map<String, String> metadata,
    String? coverPath,
  ) async {
    final fields = AudioMetadataMapper.vorbisToNativeChunkFields(metadata);
    if (coverPath != null && coverPath.trim().isNotEmpty) {
      fields['cover_path'] = coverPath;
    }
    if (fields.isEmpty) return true;
    try {
      final result = await PlatformBridge.editFileMetadata(path, fields);
      if (result['error'] != null) {
        _log.w('editFileMetadata for $path failed: ${result['error']}');
        return false;
      }
      return result['success'] == true;
    } catch (e) {
      _log.w('editFileMetadata for $path failed: $e');
      return false;
    }
  }

  static Future<void> writeM4AFreeformTags(
    String path,
    Map<String, String> metadata,
  ) async {
    final fields = <String, String>{};
    for (final entry in metadata.entries) {
      final key = entry.key.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
      switch (key) {
        case 'ISRC':
          fields['isrc'] = entry.value;
          break;
        case 'LABEL':
        case 'ORGANIZATION':
          fields['label'] = entry.value;
          break;
      }
    }
    if (fields.isEmpty) return;
    try {
      await PlatformBridge.writeM4AFreeformTags(path, fields);
    } catch (e) {
      _log.w('writeM4AFreeformTags failed for $path: $e');
    }
  }

  static Future<bool> writeM4AReleaseIdentityTags(
    String path,
    Map<String, String> metadata,
  ) async {
    final fields = AudioMetadataMapper.m4aReleaseIdentityFields(metadata);
    if (fields.isEmpty) return true;
    try {
      final result = await PlatformBridge.editFileMetadata(path, fields);
      if (result['error'] != null || result['method'] != 'native_m4a') {
        _log.w('Native M4A release identity write was not completed for $path');
        return false;
      }
      return true;
    } catch (e) {
      _log.w('M4A release identity write failed for $path: $e');
      return false;
    }
  }
}
