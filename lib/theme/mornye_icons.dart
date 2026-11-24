import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';
import 'package:mornye/theme/mornye_theme.dart';

/// [CupertinoIcons.arrow_right] that points the other way in right-to-left
/// layouts, as the chevrons [CupertinoIcons.back] and
/// [CupertinoIcons.forward] do.
const IconData mornyeArrowForward = IconData(
  0xf50a,
  fontFamily: CupertinoIcons.iconFont,
  fontPackage: CupertinoIcons.iconFontPackage,
  matchTextDirection: true,
);

/// Cupertino counterparts for the shared Settings and extension UI symbols.
/// Directional chevrons use the glyphs that mirror in right-to-left layouts
/// ([CupertinoIcons.back], not [CupertinoIcons.chevron_back]).
IconData mornyeIconFor(IconData icon) {
  if (icon.fontFamily == CupertinoIcons.iconFont) return icon;
  // The switch compares each pattern in turn; rows look icons up per build.
  return _mornyeIcons[icon] ??= _cupertinoFor(icon);
}

final _mornyeIcons = <IconData, IconData>{};

IconData _cupertinoFor(IconData icon) {
  return switch (icon) {
    Icons.extension ||
    Icons.extension_outlined ||
    Icons.extension_rounded ||
    Icons.apps ||
    Icons.grid_view ||
    Icons.grid_view_outlined ||
    Icons.grid_view_rounded => CupertinoIcons.square_grid_2x2,
    Icons.palette_outlined ||
    Icons.color_lens_outlined => CupertinoIcons.paintbrush,
    Icons.library_music ||
    Icons.library_music_outlined ||
    Icons.playlist_play_outlined ||
    Icons.queue_music_outlined => CupertinoIcons.music_note_list,
    Icons.sell_outlined ||
    Icons.label_outline ||
    Icons.tag => CupertinoIcons.tag,
    Icons.lyrics ||
    Icons.lyrics_outlined ||
    Icons.subtitles_outlined ||
    Icons.forum_outlined => CupertinoIcons.quote_bubble,
    Icons.download ||
    Icons.download_outlined ||
    Icons.file_download_outlined ||
    Icons.downloading_outlined => CupertinoIcons.arrow_down_circle,
    Icons.folder_outlined ||
    Icons.folder_open ||
    Icons.folder_special ||
    Icons.folder_special_outlined ||
    Icons.drive_file_move_outlined => CupertinoIcons.folder,
    Icons.create_new_folder_outlined => CupertinoIcons.folder_badge_plus,
    Icons.storage_outlined ||
    Icons.sd_storage_outlined ||
    Icons.memory_outlined ||
    Icons.usb_rounded => CupertinoIcons.tray,
    Icons.settings_backup_restore ||
    Icons.history ||
    Icons.history_toggle_off_outlined => CupertinoIcons.clock,
    Icons.article_outlined ||
    Icons.source_outlined ||
    Icons.insert_drive_file_outlined => CupertinoIcons.doc_text,
    Icons.favorite_outline || Icons.favorite_border => CupertinoIcons.heart,
    Icons.favorite => CupertinoIcons.heart_fill,
    Icons.push_pin_outlined => CupertinoIcons.pin,
    // The filled pin marks Unpin, as the slashed pin does in Mornye.
    Icons.push_pin => CupertinoIcons.pin_slash,
    Icons.vertical_align_top => CupertinoIcons.arrow_up_to_line,
    Icons.arrow_back || Icons.chevron_left => CupertinoIcons.back,
    Icons.chevron_right => CupertinoIcons.forward,
    Icons.arrow_forward || Icons.arrow_forward_rounded => mornyeArrowForward,
    Icons.restart_alt ||
    Icons.restart_alt_rounded => CupertinoIcons.arrow_counterclockwise,
    Icons.cast || Icons.cast_connected => CupertinoIcons.tv,
    Icons.translate_rounded => CupertinoIcons.globe,
    Icons.delete || Icons.delete_rounded => CupertinoIcons.trash,
    Icons.more_vert || Icons.more_vert_rounded => CupertinoIcons.ellipsis,
    Icons.more_horiz || Icons.more_horiz_rounded => CupertinoIcons.ellipsis,
    Icons.pause || Icons.pause_rounded => CupertinoIcons.pause_fill,
    Icons.skip_next || Icons.skip_next_rounded => CupertinoIcons.forward_fill,
    Icons.skip_previous ||
    Icons.skip_previous_rounded => CupertinoIcons.backward_fill,
    Icons.repeat || Icons.repeat_rounded => CupertinoIcons.repeat,
    Icons.repeat_one || Icons.repeat_one_rounded => CupertinoIcons.repeat_1,
    Icons.volume_up || Icons.volume_up_rounded => CupertinoIcons.volume_up,
    Icons.volume_off || Icons.volume_off_rounded => CupertinoIcons.volume_off,
    Icons.trending_up => CupertinoIcons.arrow_up_right,
    Icons.priority_high_rounded => CupertinoIcons.exclamationmark,
    Icons.campaign_rounded => CupertinoIcons.speaker_2,
    Icons.mic_none || Icons.mic_none_outlined => CupertinoIcons.mic,
    Icons.new_releases_outlined => CupertinoIcons.star_circle,
    Icons.link_off => CupertinoIcons.minus_circle,
    Icons.gpp_maybe_outlined => CupertinoIcons.exclamationmark_shield,
    Icons.person_rounded => CupertinoIcons.person,
    Icons.queue_music_rounded => CupertinoIcons.music_note_list,
    Icons.music_note_rounded => CupertinoIcons.music_note,
    Icons.album_rounded => CupertinoIcons.square_stack,
    Icons.folder || Icons.folder_rounded => CupertinoIcons.folder,
    Icons.clear || Icons.clear_rounded => CupertinoIcons.xmark,
    Icons.edit || Icons.edit_rounded => CupertinoIcons.pencil,
    Icons.save ||
    Icons.save_outlined ||
    Icons.save_rounded => CupertinoIcons.square_arrow_down,
    Icons.playlist_remove => CupertinoIcons.text_badge_minus,
    Icons.lyrics_rounded => CupertinoIcons.quote_bubble,
    Icons.headphones || Icons.headphones_outlined => CupertinoIcons.headphones,
    Icons.equalizer ||
    Icons.equalizer_rounded => CupertinoIcons.slider_horizontal_3,
    Icons.bar_chart || Icons.bar_chart_rounded => CupertinoIcons.chart_bar,
    Icons.auto_graph => CupertinoIcons.chart_bar,
    Icons.schedule || Icons.access_time => CupertinoIcons.clock,
    Icons.location_on || Icons.location_on_outlined => CupertinoIcons.location,
    Icons.confirmation_number_outlined => CupertinoIcons.ticket,
    Icons.verified || Icons.verified_outlined => CupertinoIcons.checkmark_seal,
    Icons.lock || Icons.lock_outline => CupertinoIcons.lock,
    Icons.lock_open || Icons.lock_open_outlined => CupertinoIcons.lock_open,
    Icons.visibility || Icons.visibility_outlined => CupertinoIcons.eye,
    Icons.visibility_off ||
    Icons.visibility_off_outlined => CupertinoIcons.eye_slash,
    Icons.keyboard || Icons.keyboard_outlined => CupertinoIcons.keyboard,
    Icons.qr_code || Icons.qr_code_2 => CupertinoIcons.qrcode,
    Icons.qr_code_scanner => CupertinoIcons.qrcode_viewfinder,
    Icons.download_done ||
    Icons.download_done_rounded => CupertinoIcons.checkmark_alt_circle,
    Icons.file_upload_outlined ||
    Icons.upload_outlined => CupertinoIcons.arrow_up_circle,
    Icons.restore ||
    Icons.restore_rounded => CupertinoIcons.arrow_counterclockwise,
    Icons.delete_forever_outlined => CupertinoIcons.trash,
    Icons.add_rounded => CupertinoIcons.add,
    Icons.remove || Icons.remove_rounded => CupertinoIcons.minus,
    Icons.expand_more ||
    Icons.keyboard_arrow_down => CupertinoIcons.chevron_down,
    Icons.expand_less || Icons.keyboard_arrow_up => CupertinoIcons.chevron_up,
    Icons.sort || Icons.sort_rounded => CupertinoIcons.sort_down,
    Icons.star || Icons.star_rounded => CupertinoIcons.star_fill,
    Icons.star_border || Icons.star_outline => CupertinoIcons.star,
    Icons.warning_outlined => CupertinoIcons.exclamationmark_triangle,
    Icons.error || Icons.error_rounded => CupertinoIcons.exclamationmark_circle,
    Icons.info || Icons.info_rounded => CupertinoIcons.info,
    Icons.search_rounded => CupertinoIcons.search,
    Icons.home ||
    Icons.home_outlined ||
    Icons.home_rounded => CupertinoIcons.house,
    Icons.library_music_rounded => CupertinoIcons.music_note_list,
    Icons.settings_rounded => CupertinoIcons.gear_alt,
    Icons.dark_mode_outlined => CupertinoIcons.moon,
    Icons.light_mode_outlined => CupertinoIcons.sun_max,
    Icons.brightness_auto_outlined => CupertinoIcons.circle_lefthalf_fill,
    Icons.audiotrack_outlined => CupertinoIcons.music_note,
    Icons.speaker || Icons.speaker_outlined => CupertinoIcons.hifispeaker,
    Icons.bluetooth => CupertinoIcons.bluetooth,
    Icons.usb => CupertinoIcons.tray,
    Icons.bolt || Icons.flash_on => CupertinoIcons.bolt,
    Icons.close || Icons.close_rounded => CupertinoIcons.xmark,
    Icons.play_arrow || Icons.play_arrow_rounded => CupertinoIcons.play_fill,
    Icons.shuffle => CupertinoIcons.shuffle,
    Icons.playlist_add || Icons.queue_music => CupertinoIcons.text_badge_plus,
    Icons.edit_outlined => CupertinoIcons.pencil,
    Icons.edit_note => CupertinoIcons.pencil_ellipsis_rectangle,
    Icons.fingerprint => CupertinoIcons.number,
    Icons.playlist_add_check ||
    Icons.playlist_add_check_circle => CupertinoIcons.text_badge_checkmark,
    Icons.add_circle_outline => CupertinoIcons.add_circled,
    Icons.format_list_numbered => CupertinoIcons.list_number,
    Icons.checklist || Icons.view_list => CupertinoIcons.list_bullet,
    Icons.calendar_today_outlined ||
    Icons.date_range ||
    Icons.today ||
    Icons.event_outlined => CupertinoIcons.calendar,
    Icons.preview_outlined => CupertinoIcons.doc_text_search,
    Icons.check || Icons.check_rounded => CupertinoIcons.checkmark,
    Icons.download_for_offline_outlined => CupertinoIcons.arrow_down_circle,
    Icons.call_split => CupertinoIcons.arrow_branch,
    Icons.download_rounded => CupertinoIcons.arrow_down,
    Icons.save_alt => CupertinoIcons.square_arrow_down,
    Icons.info_outline => CupertinoIcons.info,
    Icons.settings || Icons.settings_outlined => CupertinoIcons.gear_alt,
    Icons.tune ||
    Icons.tune_outlined ||
    Icons.tune_rounded ||
    Icons.table_chart_outlined => CupertinoIcons.slider_horizontal_3,
    Icons.build || Icons.build_outlined => CupertinoIcons.wrench,
    Icons.people_alt_outlined ||
    Icons.people_outline => CupertinoIcons.person_2,
    Icons.person ||
    Icons.person_outline ||
    Icons.person_outline_rounded ||
    Icons.person_search_outlined => CupertinoIcons.person,
    Icons.group_remove_outlined =>
      CupertinoIcons.person_crop_circle_badge_xmark,
    Icons.photo_size_select_large_outlined ||
    Icons.image_outlined ||
    Icons.wallpaper => CupertinoIcons.photo,
    Icons.photo_library_outlined => CupertinoIcons.photo_on_rectangle,
    Icons.compress_outlined => CupertinoIcons.arrow_down_right_arrow_up_left,
    Icons.segment_outlined => CupertinoIcons.text_alignleft,
    Icons.graphic_eq ||
    Icons.graphic_eq_outlined ||
    Icons.graphic_eq_rounded => CupertinoIcons.waveform,
    Icons.filter_alt_outlined ||
    Icons.filter_list ||
    Icons.filter_list_outlined => CupertinoIcons.line_horizontal_3_decrease,
    Icons.travel_explore ||
    Icons.language ||
    Icons.language_outlined ||
    Icons.public ||
    Icons.translate ||
    Icons.translate_outlined => CupertinoIcons.globe,
    Icons.text_fields ||
    Icons.text_fields_outlined => CupertinoIcons.textformat,
    Icons.record_voice_over_outlined => CupertinoIcons.mic,
    Icons.music_note ||
    Icons.audio_file_outlined ||
    Icons.audiotrack ||
    Icons.music_note_outlined => CupertinoIcons.music_note,
    Icons.speed ||
    Icons.speed_outlined ||
    Icons.speed_rounded => CupertinoIcons.gauge,
    Icons.auto_fix_high ||
    Icons.auto_fix_high_outlined ||
    Icons.auto_awesome ||
    Icons.auto_awesome_outlined => CupertinoIcons.wand_stars,
    Icons.wifi => CupertinoIcons.wifi,
    Icons.signal_cellular_alt => CupertinoIcons.antenna_radiowaves_left_right,
    Icons.cloud || Icons.cloud_outlined => CupertinoIcons.cloud,
    Icons.cloud_upload_outlined => CupertinoIcons.cloud_upload,
    Icons.high_quality => CupertinoIcons.hifispeaker,
    Icons.spatial_audio_outlined => CupertinoIcons.headphones,
    Icons.four_k => CupertinoIcons.waveform,
    Icons.dynamic_feed_outlined ||
    Icons.tab_outlined => CupertinoIcons.square_on_square,
    Icons.security || Icons.security_outlined => CupertinoIcons.lock_shield,
    Icons.lan_outlined || Icons.link => CupertinoIcons.link,
    Icons.sync ||
    Icons.sync_rounded ||
    Icons.autorenew_rounded => CupertinoIcons.arrow_2_circlepath,
    Icons.refresh ||
    Icons.refresh_rounded ||
    Icons.update ||
    Icons.system_update => CupertinoIcons.arrow_clockwise,
    Icons.undo => CupertinoIcons.arrow_uturn_left,
    Icons.content_copy_outlined ||
    Icons.content_copy_rounded ||
    Icons.copy_all_rounded ||
    Icons.copy_outlined ||
    Icons.copy_rounded ||
    Icons.copy => CupertinoIcons.doc_on_doc,
    Icons.swap_horiz ||
    Icons.swap_horiz_rounded ||
    Icons.compare_arrows ||
    Icons.difference_outlined ||
    Icons.alt_route => CupertinoIcons.arrow_right_arrow_left,
    Icons.cleaning_services_outlined => CupertinoIcons.sparkles,
    Icons.delete_outline ||
    Icons.delete_forever ||
    Icons.delete_sweep_outlined => CupertinoIcons.trash,
    Icons.open_in_new ||
    Icons.open_in_new_rounded ||
    Icons.open_in_browser => CupertinoIcons.arrow_up_right_square,
    Icons.play_circle_outline => CupertinoIcons.play_circle,
    Icons.share ||
    Icons.share_outlined ||
    Icons.ios_share => CupertinoIcons.share,
    Icons.brightness_2 || Icons.dark_mode => CupertinoIcons.moon,
    Icons.light_mode => CupertinoIcons.sun_max,
    Icons.contrast ||
    Icons.brightness_auto => CupertinoIcons.circle_lefthalf_fill,
    Icons.animation => CupertinoIcons.play_rectangle,
    Icons.blur_on => CupertinoIcons.drop,
    Icons.new_releases => CupertinoIcons.star_circle,
    Icons.bug_report || Icons.bug_report_outlined => CupertinoIcons.ant,
    Icons.timer_outlined => CupertinoIcons.timer,
    Icons.timer_off_outlined => CupertinoIcons.timer,
    Icons.mic => CupertinoIcons.mic_fill,
    Icons.bedtime_outlined => CupertinoIcons.moon_zzz,
    Icons.explore_outlined => CupertinoIcons.compass,
    Icons.vpn_key_outlined ||
    Icons.screen_lock_portrait_outlined => CupertinoIcons.lock,
    Icons.bookmark_outline => CupertinoIcons.bookmark,
    Icons.low_priority => CupertinoIcons.sort_down,
    Icons.search || Icons.manage_search => CupertinoIcons.search,
    Icons.add => CupertinoIcons.add,
    Icons.code => CupertinoIcons.chevron_left_slash_chevron_right,
    Icons.lightbulb_outline => CupertinoIcons.lightbulb,
    Icons.telegram => CupertinoIcons.paperplane,
    Icons.album || Icons.album_outlined => CupertinoIcons.square_stack,
    Icons.category_outlined => CupertinoIcons.guitars,
    Icons.playlist_play => CupertinoIcons.music_note_list,
    Icons.video_library ||
    Icons.video_library_outlined ||
    Icons.smart_display_outlined => CupertinoIcons.play_rectangle,
    Icons.podcasts => CupertinoIcons.mic,
    Icons.monitor_heart_outlined => CupertinoIcons.waveform_path_ecg,
    Icons.warning_amber_rounded ||
    Icons.warning_amber_outlined => CupertinoIcons.exclamationmark_triangle,
    Icons.error_outline => CupertinoIcons.exclamationmark_circle,
    Icons.cancel_outlined => CupertinoIcons.xmark_circle,
    Icons.check_circle ||
    Icons.check_circle_outline => CupertinoIcons.checkmark_circle,
    Icons.help_outline => CupertinoIcons.question_circle,
    Icons.phone_android => CupertinoIcons.device_phone_portrait,
    // Cupertino has no glyph of several devices.
    Icons.computer || Icons.devices => CupertinoIcons.desktopcomputer,
    Icons.hub_outlined => CupertinoIcons.link,
    Icons.campaign_outlined => CupertinoIcons.speaker_2,
    Icons.drag_handle => CupertinoIcons.line_horizontal_3,
    Icons.swap_vert => CupertinoIcons.arrow_up_arrow_down,
    Icons.file_open_outlined => CupertinoIcons.doc,
    Icons.directions_car => CupertinoIcons.car_detailed,
    // Preserve meaning for symbols without a Cupertino counterpart, such as
    // numbered download limits. An unrelated gear hides the action's purpose.
    _ => icon,
  };
}

extension MornyeIconContext on BuildContext {
  /// [icon] as-is, or its Cupertino counterpart when the Mornye theme is on.
  IconData adaptiveIcon(IconData icon) => isMornye ? mornyeIconFor(icon) : icon;
}
