#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 NORMALIZED_DATASET_ROOT NEW_OUTPUT_ROOT" >&2
  exit 64
fi

source_root=$1
output_root=$2
dataset_name=KNOCK_KNOCK_VOICE_GOLDEN_V2.json
generated_name=voice-golden-v2-generated
manifest_name=audio-manifest.jsonl

for command_name in say ffmpeg ffprobe jq shasum base64 sw_vers; do
  command -v "$command_name" >/dev/null || {
    echo "$command_name is required" >&2
    exit 69
  }
done

[[ -f "$source_root/$dataset_name" ]] || {
  echo "dataset JSON is missing from source root" >&2
  exit 66
}
[[ -f "$source_root/$generated_name/$manifest_name" ]] || {
  echo "audio manifest is missing from source root" >&2
  exit 66
}
[[ ! -e "$output_root" ]] || {
  echo "output root already exists; refusing to overwrite it" >&2
  exit 73
}

mkdir -p "$output_root"
cp -R "$source_root/." "$output_root/"

temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/knock-knock-voice-local.XXXXXX")
cleanup() {
  find "$temporary_root" -depth -delete
}
trap cleanup EXIT

mean_volume_db() {
  local audio_path=$1
  ffmpeg -hide_banner -nostats -i "$audio_path" -af volumedetect -f null - 2>&1 \
    | awk '/mean_volume:/ {print $(NF - 1)}'
}

measured_snr_db() {
  local clean_path=$1
  local mixed_path=$2
  local measurement_id=$3
  local clean_pcm="$temporary_root/${measurement_id}-clean.pcm"
  local mixed_pcm="$temporary_root/${measurement_id}-mixed.pcm"
  local clean_samples="$temporary_root/${measurement_id}-clean.txt"
  local mixed_samples="$temporary_root/${measurement_id}-mixed.txt"

  ffmpeg -hide_banner -loglevel error -y -i "$clean_path" -f s16le -acodec pcm_s16le "$clean_pcm"
  ffmpeg -hide_banner -loglevel error -y -i "$mixed_path" -f s16le -acodec pcm_s16le "$mixed_pcm"
  od -An -v -td2 "$clean_pcm" | awk '{for (i = 1; i <= NF; i++) print $i}' >"$clean_samples"
  od -An -v -td2 "$mixed_pcm" | awk '{for (i = 1; i <= NF; i++) print $i}' >"$mixed_samples"
  paste "$clean_samples" "$mixed_samples" \
    | awk '{signal += $1 * $1; difference = $2 - $1; noise += difference * difference}
      END {
        if (noise <= 0 || signal <= 0) exit 1
        printf "%.3f", 10 * log(signal / noise) / log(10)
      }'
}

dataset_path="$output_root/$dataset_name"
index=0
while IFS=$'\t' read -r example_id locale encoded_text; do
  text=$(printf '%s' "$encoded_text" | base64 --decode)
  case "$locale" in
    en-HK)
      voices=("Daniel" "Karen")
      ;;
    zh-Hans-HK)
      voices=("Tingting" "Eddy (Chinese (China mainland))")
      ;;
    yue-Hant-HK)
      voices=("Sinji" "Sinji")
      ;;
    *)
      echo "unsupported locale: $locale" >&2
      exit 65
      ;;
  esac
  clean_voice=${voices[$((index % 2))]}
  fast_voice=${voices[$(((index + 1) % 2))]}

  clean_aiff="$temporary_root/${example_id}-clean.aiff"
  fast_aiff="$temporary_root/${example_id}-fast.aiff"
  audio_root="$output_root/$generated_name/audio/$locale"
  mkdir -p "$audio_root"
  clean_wav="$audio_root/${example_id}__clean_normal.wav"
  fast_wav="$audio_root/${example_id}__fast_phone.wav"
  noise_wav="$audio_root/${example_id}__noise_snr15.wav"
  noise_source="$temporary_root/${example_id}-pink-noise.wav"

  say -v "$clean_voice" -r 180 -o "$clean_aiff" -- "$text"
  say -v "$fast_voice" -r 207 -o "$fast_aiff" -- "$text"

  ffmpeg -hide_banner -loglevel error -y -i "$clean_aiff" \
    -af "loudnorm=I=-23:TP=-3:LRA=7,alimiter=limit=0.95" \
    -ar 16000 -ac 1 -c:a pcm_s16le "$clean_wav"
  ffmpeg -hide_banner -loglevel error -y -i "$fast_aiff" \
    -af "highpass=f=300,lowpass=f=3400,loudnorm=I=-23:TP=-3:LRA=7,alimiter=limit=0.95" \
    -ar 16000 -ac 1 -c:a pcm_s16le "$fast_wav"

  seed=$((1000 + index))
  duration_seconds=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$clean_wav")
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "anoisesrc=color=pink:sample_rate=16000:amplitude=0.2:seed=$seed:duration=$duration_seconds" \
    -ar 16000 -ac 1 -c:a pcm_s16le "$noise_source"
  signal_mean_db=$(mean_volume_db "$clean_wav")
  noise_mean_db=$(mean_volume_db "$noise_source")
  noise_gain_db=$(awk -v signal="$signal_mean_db" -v noise="$noise_mean_db" \
    'BEGIN {printf "%.3f", signal - noise - 15.0}')
  ffmpeg -hide_banner -loglevel error -y \
    -i "$clean_wav" -i "$noise_source" \
    -filter_complex \
      "[1:a]volume=${noise_gain_db}dB[n];[0:a][n]amix=inputs=2:duration=first:normalize=0[out]" \
    -map "[out]" -ar 16000 -ac 1 -c:a pcm_s16le "$noise_wav"
  actual_snr_db=$(measured_snr_db "$clean_wav" "$noise_wav" "$example_id")
  awk -v snr="$actual_snr_db" 'BEGIN {exit !(snr >= 14.0 && snr <= 16.0)}' || {
    echo "$example_id noise profile measured ${actual_snr_db} dB; expected 14-16 dB" >&2
    exit 65
  }

  index=$((index + 1))
done < <(
  jq -r '.examples[] | [.id, .locale, (.text | @base64)] | @tsv' \
    "$dataset_path"
)

[[ $index -eq 48 ]] || {
  echo "expected 48 examples, generated $index" >&2
  exit 65
}

manifest_path="$output_root/$generated_name/$manifest_name"
updated_manifest="$temporary_root/$manifest_name"
engine="Apple say macOS $(sw_vers -productVersion); $(ffmpeg -version | sed -n '1s/ Copyright.*//p')"

while IFS= read -r row; do
  relative_path=$(jq -r '.relative_path' <<<"$row")
  case "$relative_path" in
    audio/*)
      example_id=$(jq -r '.example_id' <<<"$row")
      profile=$(jq -r '.profile' <<<"$row")
      locale=$(jq -r --arg id "$example_id" '.examples[] | select(.id == $id) | .locale' "$dataset_path")
      example_index=$(jq -r --arg id "$example_id" '.examples | map(.id) | index($id)' "$dataset_path")
      rotation_exception=""
      case "$locale" in
        en-HK)
          voices=("Daniel" "Karen")
          ;;
        zh-Hans-HK)
          voices=("Tingting" "Eddy (Chinese (China mainland))")
          ;;
        yue-Hant-HK)
          voices=("Sinji" "Sinji")
          rotation_exception="macOS 26.6 exposes one native zh_HK Cantonese voice"
          ;;
        *)
          echo "unexpected locale in manifest: $locale" >&2
          exit 65
          ;;
      esac
      clean_voice=${voices[$((example_index % 2))]}
      fast_voice=${voices[$(((example_index + 1) % 2))]}
      case "$profile" in
        clean_normal)
          voice_id="$clean_voice"
          transform="say rate=180; loudnorm -23 LUFS; limiter 0.95"
          ;;
        fast_phone)
          voice_id="$fast_voice"
          transform="say rate=207; highpass 300 Hz; lowpass 3400 Hz; loudnorm -23 LUFS; limiter 0.95"
          ;;
        noise_snr15)
          voice_id="$clean_voice"
          transform="clean_normal plus RMS-calibrated deterministic pink non-speech noise at 15 dB SNR"
          ;;
        *)
          echo "unexpected profile: $profile" >&2
          exit 65
          ;;
      esac
      audio_path="$output_root/$generated_name/$relative_path"
      sha256=$(shasum -a 256 "$audio_path" | awk '{print $1}')
      duration_seconds=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$audio_path")
      duration_milliseconds=$(jq -n --arg seconds "$duration_seconds" '$seconds | tonumber * 1000 | round')
      jq -c \
        --arg sha256 "$sha256" \
        --arg engine "$engine" \
        --arg voice_id "$voice_id" \
        --arg transform "$transform" \
        --arg locale "$locale" \
        --arg rotation_exception "$rotation_exception" \
        --argjson duration_ms "$duration_milliseconds" \
        '.sha256 = $sha256
          | .duration_ms = $duration_ms
          | .sample_rate_hz = 16000
          | .channels = 1
          | .source_type = "synthetic"
          | .tts_engine = $engine
          | .voice_id = $voice_id
          | .transform = $transform
          | .locale = $locale
          | if $rotation_exception == "" then del(.voice_rotation_exception)
            else .voice_rotation_exception = $rotation_exception end' <<<"$row" >>"$updated_manifest"
      ;;
    *)
      printf '%s\n' "$row" >>"$updated_manifest"
      ;;
  esac
done <"$manifest_path"

mv "$updated_manifest" "$manifest_path"

row_count=$(wc -l <"$manifest_path" | tr -d ' ')
unique_hash_count=$(jq -r '.sha256' "$manifest_path" | sort -u | wc -l | tr -d ' ')
wav_count=$(find "$output_root/$generated_name/audio" -type f -name '*.wav' | wc -l | tr -d ' ')
[[ $row_count -eq 144 && $wav_count -eq 144 && $unique_hash_count -eq 144 ]] || {
  echo "generated package failed uniqueness gate: rows=$row_count wav=$wav_count unique_hashes=$unique_hash_count" >&2
  exit 65
}

echo "Local voice dataset regenerated: rows=$row_count wav=$wav_count unique_hashes=$unique_hash_count"
