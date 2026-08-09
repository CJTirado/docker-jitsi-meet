#!/bin/bash
#
# Fortress (FOR-59): Jibri invokes this as `finalize-recording.sh <session-recording-dir>`
# once a recording session ends (see jibri.recording.finalize-script in jibri.conf, and
# JibriServiceFinalizeCommandRunner.kt, which runs it and blocks on it). The live capture
# (see FileSink.kt's segment-recording support and jibri.conf's segment-time) writes rolling
# 30s MKV segments instead of one continuous file, so that an abrupt Jibri/ffmpeg crash
# costs at most one segment rather than the whole deposition. This script:
#   1. concatenates those segments into one master MKV (kept indefinitely, untouched),
#   2. remuxes that into the MP4 (H.264/AAC) file the rest of the platform expects,
#   3. validates the MP4 against the master before treating it as deliverable,
#   4. hashes both files for chain-of-custody, and
#   5. best-effort reports the outcome to the deposition's audit log.
# A validation failure never deletes anything and never leaves a corrupt file at the
# expected delivery path -- see handle_validation_failure below.

set -u
set -o pipefail

SESSION_DIR="${1:?usage: finalize-recording.sh <session-recording-directory>}"
DURATION_TOLERANCE_SECONDS="${JIBRI_FINALIZE_DURATION_TOLERANCE:-1.0}"

log() {
    echo "[finalize-recording] $*" >&2
}

# Best-effort POST to the deposition's chain-of-custody audit log -- same
# auditLogUrl/sessions/:id/audit-events endpoint and {timestamp, type, detail} event shape
# the client already posts lockdown-audit/recording-config events to (see
# react/features/lockdown-audit/functions.ts and react/features/recording-config/functions.ts).
# Jibri has no per-user session JWT to sign with, so JIBRI_AUDIT_LOG_JWT is a separate,
# statically-provisioned service credential. Both env vars are optional -- if either the
# URL or the JWT is unset (the audit backend isn't configured in every deployment yet),
# this just logs locally and returns success, since a missing audit sink must never block
# or fail a recording finalize.
post_audit_event() {
    local event_type="$1"
    local detail="$2"

    if [ -z "${JIBRI_AUDIT_LOG_URL:-}" ] || [ -z "${JIBRI_AUDIT_LOG_JWT:-}" ]; then
        log "audit log not configured, skipping audit event '$event_type': $detail"
        return 0
    fi

    local session_id timestamp_ms payload
    session_id="$(basename "$SESSION_DIR")"
    timestamp_ms="$(( $(date +%s%N) / 1000000 ))"
    payload="$(jq -nc --argjson timestamp "$timestamp_ms" --arg type "$event_type" --arg detail "$detail" \
        '{timestamp: $timestamp, type: $type, detail: $detail}')"

    if ! curl -sf --max-time 15 -X POST \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${JIBRI_AUDIT_LOG_JWT}" \
            -d "$payload" \
            "${JIBRI_AUDIT_LOG_URL%/}/sessions/${session_id}/audit-events" > /dev/null; then
        log "WARNING: failed to POST audit event '$event_type' (finalize proceeds regardless)"
    fi
}

# ffprobe helper: prints one entry (format duration, or a stream's codec_name) or "" if
# absent/unreadable.
probe() {
    ffprobe -v error -show_entries "$1" -of default=noprint_wrappers=1:nokey=1 "$2" 2>/dev/null
}

hash_file() {
    local file="$1"
    local hash
    hash="$(sha256sum "$file" | cut -d' ' -f1)"
    echo "$hash  $(basename "$file")" > "${file}.sha256"
    echo "$hash"
}

# Renames a bad delivered file out of the way instead of deleting it, so a corrupt MP4
# never sits at the path other systems expect to find the deliverable at, while still
# preserving it (alongside the untouched master MKV) for post-mortem investigation.
handle_validation_failure() {
    local delivered="$1"
    local reason="$2"

    log "ERROR: validation failed for $delivered: $reason"
    if [ -f "$delivered" ]; then
        mv "$delivered" "${delivered}.invalid"
    fi
    post_audit_event "recording_finalize_validation_failed" \
        "$(basename "$delivered"): $reason. Master MKV retained; suspect MP4 kept as $(basename "$delivered").invalid for review."
}

validate_delivered_file() {
    local master="$1"
    local delivered="$2"

    if [ ! -s "$delivered" ]; then
        handle_validation_failure "$delivered" "output file missing or empty"
        return 1
    fi

    if ! ffprobe -v error "$delivered" > /dev/null 2>&1; then
        handle_validation_failure "$delivered" "ffprobe could not parse the file (likely truncated/corrupt)"
        return 1
    fi

    local video_codec audio_codec
    video_codec="$(probe "stream=codec_name" "$delivered" | sed -n '1p')"
    audio_codec="$(probe "stream=codec_name" "$delivered" | sed -n '2p')"
    if [ "$video_codec" != "h264" ]; then
        handle_validation_failure "$delivered" "expected h264 video stream, found '${video_codec:-none}'"
        return 1
    fi
    if [ "$audio_codec" != "aac" ]; then
        handle_validation_failure "$delivered" "expected aac audio stream, found '${audio_codec:-none}'"
        return 1
    fi

    local master_duration delivered_duration duration_diff
    master_duration="$(probe "format=duration" "$master")"
    delivered_duration="$(probe "format=duration" "$delivered")"
    if [ -z "$master_duration" ] || [ -z "$delivered_duration" ]; then
        handle_validation_failure "$delivered" "could not read duration from master and/or delivered file"
        return 1
    fi
    duration_diff="$(awk -v a="$master_duration" -v b="$delivered_duration" 'BEGIN { d = a - b; if (d < 0) d = -d; print d }')"
    if ! awk -v d="$duration_diff" -v tol="$DURATION_TOLERANCE_SECONDS" 'BEGIN { exit !(d <= tol) }'; then
        handle_validation_failure "$delivered" \
            "duration mismatch: master=${master_duration}s delivered=${delivered_duration}s diff=${duration_diff}s (tolerance ${DURATION_TOLERANCE_SECONDS}s)"
        return 1
    fi

    # Exact frame-count comparison on the video stream: the definitive check that the
    # remux is a lossless, complete copy of the master rather than a partial/damaged one.
    # -count_frames makes ffprobe decode the whole stream, so this is the slow part of
    # finalize -- acceptable here since finalize already runs asynchronously, off the
    # live-call path.
    # Using -count_frames requires selecting the stream explicitly, which probe() doesn't
    # support, so query directly here rather than through that helper.
    local master_frames delivered_frames
    master_frames="$(ffprobe -v error -select_streams v:0 -count_frames \
        -show_entries stream=nb_read_frames -of default=noprint_wrappers=1:nokey=1 "$master" 2>/dev/null)"
    delivered_frames="$(ffprobe -v error -select_streams v:0 -count_frames \
        -show_entries stream=nb_read_frames -of default=noprint_wrappers=1:nokey=1 "$delivered" 2>/dev/null)"
    if [ -z "$master_frames" ] || [ -z "$delivered_frames" ]; then
        handle_validation_failure "$delivered" "could not read video frame count from master and/or delivered file"
        return 1
    fi
    if [ "$master_frames" != "$delivered_frames" ]; then
        handle_validation_failure "$delivered" \
            "video frame count mismatch: master=${master_frames} delivered=${delivered_frames}"
        return 1
    fi

    # Decoded-content hash comparison (ticket-mandated, on top of the frame-count check
    # above): the md5 muxer decodes every frame of every stream and hashes the raw
    # samples, so unlike the container-level sha256 files we write later (which would
    # differ between an mkv and mp4 container even for byte-identical media), this
    # catches silent corruption/truncation introduced by the remux itself -- both files
    # must decode to the exact same content, not just the same frame count.
    local master_content_hash delivered_content_hash
    master_content_hash="$(ffmpeg -v error -i "$master" -f md5 - 2>/dev/null)"
    delivered_content_hash="$(ffmpeg -v error -i "$delivered" -f md5 - 2>/dev/null)"
    if [ -z "$master_content_hash" ] || [ -z "$delivered_content_hash" ]; then
        handle_validation_failure "$delivered" "could not compute decoded-content hash for master and/or delivered file"
        return 1
    fi
    if [ "$master_content_hash" != "$delivered_content_hash" ]; then
        handle_validation_failure "$delivered" \
            "decoded content mismatch: master ${master_content_hash} != delivered ${delivered_content_hash}"
        return 1
    fi

    return 0
}

main() {
    cd "$SESSION_DIR" || { log "ERROR: cannot cd to $SESSION_DIR"; exit 1; }

    # FileSink (see FileSink.kt) names segments "<callname>_<timestamp>_%05d.mkv" -- `ls | sort`
    # sorts lexically, which matches numeric/chronological order for the fixed-width counter.
    local segments=()
    # Matches only the "_NNNNN.mkv" segment-counter pattern FileSink emits -- not a bare
    # "*.mkv", so a re-run of finalize against a directory that already holds a previous
    # run's own master.mkv output doesn't feed that file back into the concat as if it
    # were another segment.
    while IFS= read -r seg; do
        segments+=("$seg")
    done < <(ls -1 -- *_[0-9][0-9][0-9][0-9][0-9].mkv 2>/dev/null | sort)

    if [ "${#segments[@]}" -eq 0 ]; then
        log "no .mkv segments found in $SESSION_DIR, nothing to finalize"
        exit 0
    fi

    # Strip the trailing "_%05d.mkv" segment counter to recover the base name shared by
    # every segment, e.g. "mycall_2026-08-09-12-00-00_00000.mkv" -> "mycall_2026-08-09-12-00-00".
    local basename_stem="${segments[0]%_*.mkv}"
    local master_mkv="${basename_stem}.mkv"
    local delivered_mp4="${basename_stem}.mp4"

    log "concatenating ${#segments[@]} segment(s) into $master_mkv"
    local concat_list
    concat_list="$(mktemp)"
    trap 'rm -f "$concat_list"' RETURN
    # Absolute paths (built from $PWD, since we already cd'd into $SESSION_DIR above): the
    # concat demuxer resolves relative entries against the concat list file's own location
    # (mktemp's, i.e. /tmp), not our cwd, so a relative path here would silently fail to
    # find the segments.
    for seg in "${segments[@]}"; do
        printf "file '%s'\n" "$PWD/$seg" >> "$concat_list"
    done

    if ! ffmpeg -y -v error -f concat -safe 0 -i "$concat_list" -c copy "$master_mkv"; then
        log "ERROR: failed to concatenate ${#segments[@]} segment(s)"
        post_audit_event "recording_finalize_failed" \
            "ffmpeg concat of ${#segments[@]} segment(s) into $master_mkv failed; raw segments retained"
        exit 1
    fi

    log "remuxing $master_mkv to $delivered_mp4"
    # -fflags +genpts: regenerate any missing/irregular presentation timestamps rather
    # than propagate them as-is, so A/V sync and duration stay correct after the remux
    # even if a segment boundary or concat introduced a small PTS irregularity.
    local remux_cmd=(ffmpeg -y -v error -fflags +genpts -i "$master_mkv" -c copy -movflags +faststart "$delivered_mp4")
    if ! "${remux_cmd[@]}"; then
        log "ERROR: failed to remux $master_mkv to $delivered_mp4"
        post_audit_event "recording_finalize_failed" \
            "remux of $master_mkv to mp4 failed; master MKV retained"
        exit 1
    fi

    if ! validate_delivered_file "$master_mkv" "$delivered_mp4"; then
        exit 1
    fi

    local master_hash delivered_hash
    master_hash="$(hash_file "$master_mkv")"
    delivered_hash="$(hash_file "$delivered_mp4")"

    log "finalize complete: $delivered_mp4 (sha256 $delivered_hash), master $master_mkv (sha256 $master_hash)"

    # Audit event for the conversion step itself (not just the file hashes): tool
    # version, exact command used, and the duration comparison -- so the chain-of-custody
    # record documents how the delivered MP4 was derived, not just what it hashes to.
    local ffmpeg_version master_duration delivered_duration
    ffmpeg_version="$(ffmpeg -version 2>/dev/null | head -n 1)"
    master_duration="$(probe "format=duration" "$master_mkv")"
    delivered_duration="$(probe "format=duration" "$delivered_mp4")"
    post_audit_event "recording_finalized" \
        "delivered=$delivered_mp4 sha256=$delivered_hash master=$master_mkv sha256=$master_hash segments=${#segments[@]} ffmpeg=[$ffmpeg_version] remux_cmd=[${remux_cmd[*]}] master_duration=${master_duration}s delivered_duration=${delivered_duration}s validation=passed"
}

main
