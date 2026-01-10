#!/bin/bash

set -euo pipefail

# ==================== LOAD CONFIGURATION ====================
CONFIG_FILE="./backup.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Source configuration
source "$CONFIG_FILE"

# Validate required variables
for var in SOURCE_DIR BACKUP_DIR BASE_PREFIX INCREMENT_PREFIX MAX_INCREMENTS FILTER_MODE NTFY_ENABLED NTFY_URL; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: Required variable $var not set in $CONFIG_FILE"
        exit 1
    fi
done

# Resolve LOG_DIR path
if [[ "$LOG_DIR" == .* ]]; then
    LOG_DIR="$BACKUP_DIR/$LOG_DIR"
fi

# Current date
DATE=$(date +%Y-%m-%d)

# ==================== FUNCTIONS ====================

# Функция логирования
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_DIR/backup.log" >&2
}

# Функция отправки уведомления в ntfy
send_ntfy() {
    local title="$1"
    local message="$2"
    local priority="${3:-default}"
    local tags="${4:-}"

    if [ "$NTFY_ENABLED" = true ]; then
        curl -s -H "Title: $title" \
            -H "Priority: $priority" \
            ${tags:+-H "Tags: $tags"} \
            -d "$message" \
            "$NTFY_URL" 2>/dev/null || log "Warning: Failed to send ntfy notification"
    fi
}

# Обработчик ошибок
error_handler() {
    local line_number=$1
    log "ERROR: Script failed at line $line_number"

    send_ntfy "Backup: FAILED" \
            "Backup script crashed!

Date: $DATE
Source: $SOURCE_DIR
Line: $line_number
Check logs: $LOG_DIR/backup.log

Last 10 log lines:
$(tail -10 $LOG_DIR/backup.log 2>/dev/null || echo 'No logs available')" \
            "urgent" "x,rotating_light"

    exit 1
}

trap 'error_handler ${LINENO}' ERR

# Найти текущую базу
find_current_base() {
    find "$BACKUP_DIR" -maxdepth 1 -type d -name "${BASE_PREFIX}*" 2>/dev/null | sed 's|.*/||' | sort | tail -1
}

# Найти все инкременты
list_increments() {
    find "$BACKUP_DIR" -maxdepth 1 -type d -name "${INCREMENT_PREFIX}20??-??-??" 2>/dev/null | sed 's|.*/||' | sort
}

# Найти самый старый инкремент
find_oldest_increment() {
    list_increments | head -1
}

# Найти самый новый инкремент
find_latest_increment() {
    list_increments | tail -1
}

# Подсчитать инкременты
count_increments() {
    list_increments | wc -l
}

# Построить фильтры для rsync
build_rsync_filters() {
    local filters=""

    if [ "$FILTER_MODE" = "exclude" ]; then
        # Exclude mode: исключить указанные паттерны
        for pattern in "${FILTER_PATTERNS[@]}"; do
            filters="$filters --exclude=$pattern"
        done
    elif [ "$FILTER_MODE" = "include" ]; then
        # Include mode: включить только указанные паттерны
        # Сначала включаем паттерны, потом исключаем всё остальное
        for pattern in "${FILTER_PATTERNS[@]}"; do
            filters="$filters --include=$pattern"
            # Если паттерн - директория, включить её содержимое рекурсивно
            if [[ "$pattern" == */ ]]; then
                filters="$filters --include=${pattern}**"
            fi
        done
        # Исключить всё остальное
        filters="$filters --exclude=*"
    else
        log "ERROR: Invalid FILTER_MODE: $FILTER_MODE (must be 'include' or 'exclude')"
        exit 1
    fi

    echo "$filters"
}

# Проверить свободное место
check_free_space() {
    local free_space_kb=$(df -k "$BACKUP_DIR" | tail -1 | awk '{print $4}')
    local free_space_gb=$((free_space_kb / 1024 / 1024))

    if [ "$free_space_gb" -lt "${MIN_FREE_SPACE_GB:-10}" ]; then
        log "WARNING: Low disk space: ${free_space_gb}GB available"
        send_ntfy "Backup: Low Disk Space" \
                "Warning: Low disk space on backup volume

Available: ${free_space_gb}GB
Threshold: ${MIN_FREE_SPACE_GB}GB
Location: $BACKUP_DIR

Backup will continue but may fail if space runs out." \
                "high" "warning,floppy_disk"
    fi
}

# Подсчитать удаленные файлы (сравнить reference с source)
count_deleted_files() {
    local reference_dir="$1"
    local source_dir="$2"

    log "=== Counting deleted files ==="
    local deleted_count=0
    local start_time=$(date +%s)

    # Создаем временный файл для списка удаленных файлов
    local deleted_list="$LOG_DIR/deleted_files_$(date +%Y%m%d_%H%M%S).txt"

    # Проходим по всем файлам в REFERENCE (предыдущем снимке)
    # Проверяем, существуют ли они в SOURCE
    # Если нет - это удаленный файл
    while IFS= read -r -d '' reference_file; do
        # Получаем относительный путь
        local rel_path="${reference_file#$reference_dir/}"
        local source_file="$source_dir/$rel_path"

        # Если файла нет в источнике - считаем удаленным
        if [ ! -e "$source_file" ]; then
            echo "$rel_path" >> "$deleted_list"
            ((deleted_count++))
        fi
    done < <(find "$reference_dir" -type f -print0 2>/dev/null)

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log "Counted $deleted_count deleted files in ${duration}s"

    # Сохраняем количество для статистики
    echo "$deleted_count"
}

# ==================== INITIALIZATION ====================

# Создать директории
mkdir -p "$BACKUP_DIR" "$LOG_DIR"

log "=== Backup Started ==="
log "Config: $CONFIG_FILE"
log "Source: $SOURCE_DIR"
log "Destination: $BACKUP_DIR"
log "Filter mode: $FILTER_MODE"
log "Filter patterns: ${FILTER_PATTERNS[*]}"

# Проверить, существует ли исходная директория
if [ ! -d "$SOURCE_DIR" ]; then
    log "ERROR: Source directory does not exist: $SOURCE_DIR"
    send_ntfy "Backup: FAILED" \
            "Source directory not found!

Source: $SOURCE_DIR
Date: $DATE

Please check configuration." \
            "urgent" "x,rotating_light"
    exit 1
fi

# Проверить свободное место
# check_free_space

# Построить фильтры rsync
RSYNC_FILTERS=$(build_rsync_filters)
log "Rsync filters: $RSYNC_FILTERS"

# Переменные для статистики
BACKUP_START_TIME=$(date +%s)
BASE_MERGED=false
NEW_BASE_NAME=""
CHANGES_MADE=false

# ==================== FIND CURRENT STATE ====================
CURRENT_BASE=$(find_current_base)

if [ -z "$CURRENT_BASE" ]; then
    log "Creating initial base..."
    BASE_NAME="${BASE_PREFIX}${DATE}"

    # shellcheck disable=SC2086
    rsync -a \
        --no-perms --no-group --no-owner \
        $RSYNC_FILTERS \
        $RSYNC_EXTRA_OPTS \
        "$SOURCE_DIR/" "$BACKUP_DIR/$BASE_NAME/" \
        2>&1 | tee -a "$LOG_DIR/backup.log"

    log "Initial base created: $BASE_NAME"

    # Уведомление о создании начальной базы
    BASE_SIZE=$(du -sh "$BACKUP_DIR/$BASE_NAME" 2>/dev/null | cut -f1)
    FILE_COUNT=$(find "$BACKUP_DIR/$BASE_NAME" -type f | wc -l)

    send_ntfy "Backup: Initial Base Created" \
            "Created initial backup base

Date: $DATE
Size: $BASE_SIZE
Files: $FILE_COUNT
Source: $SOURCE_DIR
Filter: $FILTER_MODE mode" \
            "default" "white_check_mark,floppy_disk"

    exit 0
fi

# ==================== CURRENT STATUS ====================
BASE_DATE=${CURRENT_BASE#$BASE_PREFIX}
INCREMENT_COUNT=$(count_increments)

log "=== Current State ==="
log "Base: $CURRENT_BASE (date: $BASE_DATE)"
log "Increments: $INCREMENT_COUNT/$MAX_INCREMENTS"

# ==================== MERGE OLDEST INCREMENT ====================
if [ "$INCREMENT_COUNT" -ge "$MAX_INCREMENTS" ]; then
    OLDEST_INCREMENT=$(find_oldest_increment)

    if [ -n "$OLDEST_INCREMENT" ]; then
        log "=== Sliding window forward ==="
        log "Merging: $OLDEST_INCREMENT -> base"

        BASE_MERGED=true

        # Удалить старую базу
        log "Removing old base: $CURRENT_BASE"
        rm -rf "$BACKUP_DIR/$CURRENT_BASE"

        # Переименовать старый инкремент в новую базу (убрать INCREMENT_PREFIX, добавить BASE_PREFIX)
        OLDEST_INCREMENT_DATE="${OLDEST_INCREMENT#$INCREMENT_PREFIX}"
        NEW_BASE="${BASE_PREFIX}${OLDEST_INCREMENT_DATE}"
        log "Promoting increment to base: $OLDEST_INCREMENT -> $NEW_BASE"
        mv "$BACKUP_DIR/$OLDEST_INCREMENT" "$BACKUP_DIR/$NEW_BASE"

        NEW_BASE_NAME="$NEW_BASE"
        log "New base: $NEW_BASE"
        CURRENT_BASE="$NEW_BASE"
    fi
fi

# ==================== CREATE NEW INCREMENT ====================
LATEST_INCREMENT=$(find_latest_increment)

if [ -n "$LATEST_INCREMENT" ]; then
    REFERENCE_DIR="$BACKUP_DIR/$LATEST_INCREMENT"
    REFERENCE_NAME="$LATEST_INCREMENT"
else
    REFERENCE_DIR="$BACKUP_DIR/$CURRENT_BASE"
    REFERENCE_NAME="$CURRENT_BASE"
fi

INCREMENT_NAME="${INCREMENT_PREFIX}${DATE}"

log "=== Creating increment: $INCREMENT_NAME ==="
log "Reference: $REFERENCE_NAME"

# Этап 1: Создать инкремент с hardlinks и фильтрами (без --delete)
log "Step 1/2: Syncing new and modified files..."
# shellcheck disable=SC2086
rsync -avh \
    --itemize-changes \
    --no-perms --no-group --no-owner \
    --link-dest="$REFERENCE_DIR" \
    $RSYNC_FILTERS \
    $RSYNC_EXTRA_OPTS \
    "$SOURCE_DIR/" "$BACKUP_DIR/$INCREMENT_NAME/" \
    > "$LOG_DIR/$INCREMENT_NAME.log" 2>&1

# Проверить код возврата rsync
# 0 = успех
# 24 = файлы исчезли во время передачи (временные файлы) - игнорировать
# 23 = частичная передача из-за ошибок - игнорировать если есть данные
RSYNC_EXIT=$?
if [ $RSYNC_EXIT -ne 0 ] && [ $RSYNC_EXIT -ne 24 ] && [ $RSYNC_EXIT -ne 23 ]; then
    log "ERROR: rsync failed with exit code $RSYNC_EXIT"
    exit 1
fi

# Этап 2: Подсчитать удаленные файлы (сравнить reference с source)
log "Step 2/2: Counting deleted files..."
DELETED_COUNT=$(count_deleted_files "$REFERENCE_DIR" "$SOURCE_DIR")

# Проверка на пустой инкремент
if [ ! "$(ls -A $BACKUP_DIR/$INCREMENT_NAME 2>/dev/null)" ]; then
    rm -rf "$BACKUP_DIR/$INCREMENT_NAME"
    log "No changes - increment not created"
    CHANGES_MADE=false
else
    CHANGES_MADE=true

    # Подсчитать изменения из rsync лога и сравнения файлов
    log "Calculating statistics from rsync log..."

    # Парсинг rsync --itemize-changes вывода
    # >f+++++++++ - новый файл
    # >f.st...... - измененный файл (размер/время)
    # Для удалений используется count_deleted_files (сравнивает reference с source)

    # Подсчитать новые файлы (все атрибуты +++++++++)
    NEW_FILES=$(grep '^>f+++++++++' "$LOG_DIR/$INCREMENT_NAME.log" 2>/dev/null | wc -l)

    # Подсчитать измененные файлы (начинается с >f но не все +)
    CHANGED_FILES=$(grep '^>f[^+]' "$LOG_DIR/$INCREMENT_NAME.log" 2>/dev/null | wc -l)

    # Удаленные файлы берем из count_deleted_files
    DELETED_FILES=$DELETED_COUNT

    # Измененные = все измененные
    MODIFIED_FILES=$CHANGED_FILES

    # Trim whitespace
    NEW_FILES=$(echo "$NEW_FILES" | tr -d '[:space:]')
    DELETED_FILES=$(echo "$DELETED_FILES" | tr -d '[:space:]')
    MODIFIED_FILES=$(echo "$MODIFIED_FILES" | tr -d '[:space:]')

    # Убедиться что это числа
    NEW_FILES=${NEW_FILES:-0}
    DELETED_FILES=${DELETED_FILES:-0}
    MODIFIED_FILES=${MODIFIED_FILES:-0}

    log "Changes: $MODIFIED_FILES modified, $NEW_FILES new, $DELETED_FILES deleted"
fi

# ==================== STATISTICS ====================
BACKUP_END_TIME=$(date +%s)
BACKUP_DURATION=$((BACKUP_END_TIME - BACKUP_START_TIME))

CURRENT_BASE=$(find_current_base)
BASE_DATE=${CURRENT_BASE#$BASE_PREFIX}
FINAL_INCREMENT_COUNT=$(count_increments)

log "=== Summary ==="
log "Base: $CURRENT_BASE (${BASE_DATE})"
log "Increments: $FINAL_INCREMENT_COUNT days"

# Размеры
BASE_SIZE=$(du -sh "$BACKUP_DIR/$CURRENT_BASE" 2>/dev/null | cut -f1)
TOTAL_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
APPARENT_TOTAL=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
log "Base size: $BASE_SIZE"
log "Total size (with hardlinks): $TOTAL_SIZE"
log "Apparent size: $APPARENT_TOTAL"

log "Backup completed successfully in ${BACKUP_DURATION}s"

# ==================== NTFY NOTIFICATION ====================

# Функция отправки с прикреплённым файлом
send_ntfy_with_attachment() {
    local title="$1"
    local message="$2"
    local priority="${3:-default}"
    local tags="${4:-}"
    local file="${5:-}"

    if [ "$NTFY_ENABLED" = true ]; then
        if [ -n "$file" ] && [ -f "$file" ]; then
            # Заменить реальные переносы строк на литеральную строку \n
            local message_oneline=$(echo "$message" | sed ':a;N;$!ba;s/\n/\\n/g')

            # Отправка файла с сообщением в одном запросе
            curl -s \
                -H "Title: $title" \
                -H "Priority: $priority" \
                ${tags:+-H "Tags: $tags"} \
                -H "Filename: $(basename "$file")" \
                -H "Message: $message_oneline" \
                -T "$file" \
                "$NTFY_URL" 2>/dev/null || log "Warning: Failed to send ntfy notification with attachment"
        else
            # Отправка без файла
            send_ntfy "$title" "$message" "$priority" "$tags"
        fi
    fi
}

# Формирование сообщения
if [ "$CHANGES_MADE" = false ]; then
    # Нет изменений
    MESSAGE="No changes detected

Source: $SOURCE_DIR
Base: $BASE_DATE
Increments: $FINAL_INCREMENT_COUNT/$MAX_INCREMENTS
Duration: ${BACKUP_DURATION}s
Total: $TOTAL_SIZE"

    send_ntfy "Backup: No Changes" "$MESSAGE" "low" "white_check_mark"

elif [ "$BASE_MERGED" = true ]; then
    # База была сдвинута + новый инкремент
    OLD_BASE_DATE="$BASE_DATE"
    NEW_BASE_DATE=${NEW_BASE_NAME#$BASE_PREFIX}

    # Создать детальную статистику по файлам
    STATS_DETAILS=""
    if [ "$MODIFIED_FILES" -gt 0 ] || [ "$NEW_FILES" -gt 0 ] || [ "$DELETED_FILES" -gt 0 ]; then
        STATS_DETAILS="
📊 Changes Statistics:
✏️  Modified: $MODIFIED_FILES files
➕ New: $NEW_FILES files
❌ Deleted: $DELETED_FILES files
📝 Total: $((MODIFIED_FILES + NEW_FILES + DELETED_FILES)) files"
    fi

    MESSAGE="Backup window slid forward!

📦 Base shifted: $OLD_BASE_DATE → $NEW_BASE_DATE
📈 New increment: $INCREMENT_NAME
$STATS_DETAILS

Source: $SOURCE_DIR
Increments: $FINAL_INCREMENT_COUNT/$MAX_INCREMENTS
Duration: ${BACKUP_DURATION}s
Total: $TOTAL_SIZE"

    send_ntfy_with_attachment "Backup: Window Shifted" "$MESSAGE" "high" "arrows_counterclockwise,floppy_disk" "$LOG_DIR/$INCREMENT_NAME.log"

else
    # Обычный инкремент
    # Создать детальную статистику по файлам
    STATS_DETAILS=""
    if [ "$MODIFIED_FILES" -gt 0 ] || [ "$NEW_FILES" -gt 0 ] || [ "$DELETED_FILES" -gt 0 ]; then
        STATS_DETAILS="
📊 Changes Statistics:
✏️  Modified: $MODIFIED_FILES files
➕ New: $NEW_FILES files
❌ Deleted: $DELETED_FILES files
📝 Total: $((MODIFIED_FILES + NEW_FILES + DELETED_FILES)) files
"
    fi

    MESSAGE="Backup completed successfully

📈 Increment: $INCREMENT_NAME
$STATS_DETAILS
Source: $SOURCE_DIR
Base: $BASE_DATE
Increments: $FINAL_INCREMENT_COUNT/$MAX_INCREMENTS
Duration: ${BACKUP_DURATION}s
Total: $TOTAL_SIZE"

    send_ntfy_with_attachment "Backup: Success" "$MESSAGE" "default" "white_check_mark,floppy_disk" "$LOG_DIR/$INCREMENT_NAME.log"
fi

log "=== Backup Finished ==="