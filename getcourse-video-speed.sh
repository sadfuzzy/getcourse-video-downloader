#!/usr/bin/env bash
# Simple script to download videos from GetCourse.ru
# on Linux/*BSD
# Dependencies: bash, coreutils, curl, grep, parallel, pv

set -eu
set +f
set -o pipefail

if [ -f "$0" ]; then
    a0="bash $0"
else
    a0="$0"
fi

_echo_help() {
    echo "
Первым аргументом должна быть ссылка на плей-лист, найденная в исходном коде страницы сайта GetCourse.
Пример: <video id=\"vgc-player_html5_api\" data-master=\"нужная ссылка\" ... />.
Вторым аргументом должен быть путь к файлу для сохранения скачанного видео, рекомендуемое расширение — ts.
Пример: \"Как скачать видео с GetCourse.ts\"
Скопируйте ссылку и запустите скрипт, например, так:
$a0 \"эта_ссылка\" \"Как скачать видео с GetCourse.ts\"
Инструкция с графическими иллюстрациями здесь: https://github.com/mikhailnov/getcourse-video-downloader
О проблемах в работе сообщайте сюда: https://github.com/mikhailnov/getcourse-video-downloader/issues
"
}

# Use a deterministic tmpdir based on the URL path (without query string) so
# re-runs with a fresh signed URL for the same video reuse already-downloaded segments
url_path=$(printf '%s' "${1:-}" | sed 's/?.*//')
if command -v md5sum >/dev/null 2>&1; then
    url_hash=$(printf '%s' "$url_path" | md5sum | cut -c1-16)
else
    url_hash=$(printf '%s' "$url_path" | md5 | cut -c1-16)
fi
tmpdir="/tmp/getcourse_${url_hash}"
umask 077 && mkdir -p "$tmpdir"
export TMPDIR="$tmpdir"

# Check for pv
if ! command -v pv >/dev/null 2>&1; then
    echo "Ошибка: 'pv' не установлен. Установите выполнив:"
    echo "Ubuntu/Debian: sudo apt-get install pv"
    echo "macOS: brew install pv"
    exit 1
fi

if [ -z "${1:-}" ] || [ -z "${2:-}" ] || [ -n "${3:-}" ]; then
    _echo_help
    exit 1
fi

URL="$1"
result_file="$2"
touch "$result_file"

# Default to 4 threads, but allow overriding with the PP environment variable
PP=${PP:-4}

main_playlist="$(mktemp)"
curl -fL --output "$main_playlist" "$URL"
second_playlist="$(mktemp)"

# Check for direct video segment URLs
if grep -qE '^https?:\/\/.*\.(ts|bin)' "$main_playlist" 2>/dev/null; then
    cp "$main_playlist" "$second_playlist"
else
    tail="$(tail -n1 "$main_playlist")"
    if ! [[ "$tail" =~ ^https?:// ]]; then
        echo "В содержимом заданной ссылки нет прямых ссылок на файлы *.bin (*.ts) (первый вариант),"
        echo "также последняя строка в ней не содержит ссылки на другой плей-лист (второй вариант)."
        echo "Либо указана неправильная ссылка, либо GetCourse изменил алгоритмы."
        echo "Если уверены, что дело в изменившихся алгоритмах GetCourse, опишите проблему здесь:"
        echo "https://github.com/mikhailnov/getcourse-video-downloader/issues (на русском)."
        exit 1
    fi
    curl -fL --output "$second_playlist" "$tail"
fi

# Export variables for use in parallel
export tmpdir

# Download segments in parallel using GNU parallel
total_segments=$(grep -c '^http' "$second_playlist" || true)
if [ "$total_segments" -eq 0 ]; then
    echo "Ошибка: сегменты не найдены в плейлисте."
    exit 1
fi

cached=$(find "$tmpdir" -name "*.ts" -size +0c | wc -l | tr -d ' ')
if [ "$cached" -gt 0 ]; then
    echo "Найдено $cached сегментов в кэше ($tmpdir), пропускаю их."
fi

echo "Скачиваю $total_segments сегментов..."
grep '^http' "$second_playlist" | parallel --bar --will-cite -j "$PP" \
    'f="${TMPDIR}/$(printf "%05d" {#}).ts"; [ -s "$f" ] || curl -s --retry 12 --retry-all-errors -L --output "$f" {}' || true

# Check how many segments actually have content
ok=$(find "$tmpdir" -name "*.ts" -size +0c | wc -l | tr -d ' ')
if [ "$ok" -eq 0 ]; then
    echo "Ошибка: ни один сегмент не был скачан. Проверьте сеть или попробуйте снова."
    exit 1
fi
if [ "$ok" -lt "$total_segments" ]; then
    echo "Предупреждение: скачано $ok из $total_segments сегментов."
fi

echo "Соединяю $ok сегментов..."
total_size=$(wc -c "$tmpdir"/*.ts | tail -1 | awk '{print $1}')
cat "$tmpdir"/*.ts | pv -s "$total_size" > "$result_file"
echo "Скачивание завершено. Результат:
$result_file"
rm -rf "$tmpdir"
