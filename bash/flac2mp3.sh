#!/bin/bash

# FLAC to MP3 Converter
# Usage: ./flac2mp3.sh [OPTIONS] <source_directory> <destination_directory>
#
# Requirements:
#   - bash 3.2 or higher
#   - ffmpeg
#
# Options:
#   --dry-run            Show files that would be converted without converting
#   --bitrate, -b RATE   MP3 bitrate (default: 320k)
#                        CBR: 320k, 256k, 192k, 128k
#                        VBR: V0 (best), V2 (high), V4 (medium), V6 (acceptable)
#   --overwrite          Overwrite existing MP3 files (default: skip existing)
#
# Arguments:
#   source_directory      - Directory containing FLAC files
#   destination_directory - Where to save converted MP3s
#
# Examples:
#   ./flac2mp3.sh /Volumes/MyDrive/Music ~/Desktop/Converted_MP3s
#   ./flac2mp3.sh --bitrate 256k ~/Music ~/Desktop/MP3s
#   ./flac2mp3.sh -b V0 ~/Music ~/Desktop/MP3s
#   ./flac2mp3.sh --dry-run --bitrate V2 ~/Music ~/Desktop/MP3s
#   ./flac2mp3.sh ~/Music ~/Desktop/MP3s --overwrite

#==============================================================================
# CONSTANTS AND CONFIGURATION
#==============================================================================

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Default configuration
readonly DEFAULT_BITRATE="320k"
OVERWRITE_EXISTING=false
DRY_RUN=false

# Global variables (set during execution)
SOURCE=""
DEST=""
BITRATE_ARG=""
BITRATE_MODE=""
FFMPEG_QUALITY_ARGS=""
PARALLEL_JOBS=0
TOTAL_FILES=0
FLAC_FILES_LIST=""

# Temp file tracking
temp_dir=""
success_file=""
skipped_file=""
failed_file=""
failed_list=""
dry_run_file=""
error_log=""
start_time=0
monitor_pid=0

#==============================================================================
# UTILITY FUNCTIONS
#==============================================================================

# Print error message and exit
error_exit() {
  echo -e "${RED}Error: $1${NC}" >&2
  exit 1
}

# Print warning message
warn() {
  echo -e "${YELLOW}Warning: $1${NC}"
}

# Print info message
info() {
  echo -e "${BLUE}$1${NC}"
}

# Print success message
success() {
  echo -e "${GREEN}$1${NC}"
}

# Cleanup temporary files
cleanup() {
  # Stop progress monitor if running
  if [ "$monitor_pid" -gt 0 ] 2>/dev/null; then
    kill "$monitor_pid" 2>/dev/null
    wait "$monitor_pid" 2>/dev/null
  fi

  # Clean up temporary conversion files (*.tmp.*)
  if [ -n "$DEST" ] && [ -d "$DEST" ]; then
    find "$DEST" -name "*.tmp.*" -type f -delete 2>/dev/null
  fi

  if [ -n "$temp_dir" ] && [ -d "$temp_dir" ]; then
    rm -rf "$temp_dir"
  fi
}

#==============================================================================
# VALIDATION FUNCTIONS
#==============================================================================

# Check if required tools are installed
check_dependencies() {
  if ! command -v ffmpeg &>/dev/null; then
    error_exit "ffmpeg is not installed"
  fi
}

# Parse and validate bitrate argument
validate_bitrate() {
  local bitrate="$1"

  if [[ "$bitrate" =~ ^[Vv][0-9]$ ]]; then
    # VBR mode
    VBR_QUALITY="${bitrate:1}"
    BITRATE_MODE="VBR"
    FFMPEG_QUALITY_ARGS="-q:a $VBR_QUALITY"
  elif [[ "$bitrate" =~ ^[0-9]+k$ ]]; then
    # CBR mode
    BITRATE_MODE="CBR"
    FFMPEG_QUALITY_ARGS="-ab $bitrate"
  else
    error_exit "Invalid bitrate format '$bitrate'. Use CBR (320k, 256k) or VBR (V0, V2, V4, V6)"
  fi
}

# Validate and resolve directory paths
# Also creates the destination directory if it doesn't exist
validate_directories() {
  # Resolve source directory to absolute path
  local resolved_source=$(cd "$SOURCE" 2>/dev/null && pwd) ||
    error_exit "Source directory does not exist: $SOURCE"
  SOURCE="$resolved_source"

  # Create destination directory if needed and resolve to absolute path
  mkdir -p "$DEST" ||
    error_exit "Cannot create destination directory: $DEST"
  local resolved_dest=$(cd "$DEST" && pwd)
  DEST="$resolved_dest"

  # Check if destination is writable
  [ -w "$DEST" ] ||
    error_exit "Destination directory is not writable: $DEST"

  # Check if source and destination are the same
  [ "$SOURCE" != "$DEST" ] ||
    error_exit "Source and destination directories cannot be the same"

  # Warn if destination is inside source
  if [[ "$DEST" == "$SOURCE"/* ]]; then
    warn "Destination is inside source directory"
    warn "This may cause the script to try converting newly created MP3s"
    read -p "Continue anyway? (y/n): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 0
  fi
}

# Check if destination has enough disk space
check_disk_space() {
  info "Checking available disk space..."

  # Get available space on destination filesystem (in KB)
  local available_kb=$(df -k "$DEST" | tail -1 | awk '{print $4}')
  local available_gb=$((available_kb / 1024 / 1024))

  # Estimate required space: assume MP3s are ~40% of FLAC size on average
  # Get total size of FLAC files (in KB)
  local flac_size_kb=0
  while IFS= read -r -d '' file; do
    local size=$(stat -f %z "$file" 2>/dev/null || echo 0)
    flac_size_kb=$((flac_size_kb + size / 1024))
  done <"$FLAC_FILES_LIST"

  # Estimate required space
  # MP3 size varies by bitrate: ~30-40% for VBR, ~40-60% for high CBR
  # Using 40% as a reasonable average estimate
  local estimated_mp3_kb=$((flac_size_kb * 40 / 100))
  local estimated_mp3_gb=$((estimated_mp3_kb / 1024 / 1024))

  # Add 10% safety margin
  local required_kb=$((estimated_mp3_kb * 110 / 100))
  local required_gb=$((required_kb / 1024 / 1024))

  info "Source FLAC size: ~$((flac_size_kb / 1024 / 1024)) GB"
  info "Estimated MP3 size: ~${estimated_mp3_gb} GB (with 10% margin: ~${required_gb} GB)"
  info "Available space: ~${available_gb} GB"

  if [ $required_kb -gt $available_kb ]; then
    error_exit "Insufficient disk space. Need ~${required_gb} GB, only ${available_gb} GB available"
  fi

  success "Sufficient disk space available"
  echo ""
}

#==============================================================================
# SETUP FUNCTIONS
#==============================================================================

# Detect and configure parallel jobs based on CPU cores
setup_parallel_jobs() {
  local cpu_cores=4 # Default fallback

  # Detect CPU cores based on OS
  if command -v nproc &>/dev/null; then
    # Linux (GNU coreutils) - most reliable
    cpu_cores=$(nproc 2>/dev/null || echo 4)
  elif [ -f /proc/cpuinfo ]; then
    # Linux fallback (read /proc/cpuinfo directly)
    cpu_cores=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 4)
  elif command -v sysctl &>/dev/null && sysctl -n hw.ncpu &>/dev/null; then
    # macOS and BSD (only if hw.ncpu actually exists)
    cpu_cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
  else
    # Unable to detect, use conservative default
    warn "Unable to detect CPU cores, using default: 4"
  fi

  # Use 75% of cores for parallel jobs
  PARALLEL_JOBS=$((cpu_cores * 3 / 4))
  # Ensure at least 1 job, max 8
  PARALLEL_JOBS=$((PARALLEL_JOBS < 1 ? 1 : PARALLEL_JOBS))
  PARALLEL_JOBS=$((PARALLEL_JOBS > 8 ? 8 : PARALLEL_JOBS))
}

# Setup temporary files for progress tracking
setup_temp_files() {
  temp_dir=$(mktemp -d)
  success_file="$temp_dir/success"
  skipped_file="$temp_dir/skipped"
  failed_file="$temp_dir/failed"
  failed_list="$temp_dir/failed_list"
  dry_run_file="$temp_dir/dry_run"
  error_log="$temp_dir/conversion_errors.log"

  echo "0" >"$success_file"
  echo "0" >"$skipped_file"
  echo "0" >"$failed_file"
  touch "$failed_list"
  touch "$error_log"

  # Setup cleanup trap
  trap cleanup EXIT INT TERM
}

# Count total FLAC files in source directory
find_and_count_flac_files() {
  info "Scanning for FLAC files..."

  # Create temp file to store list of FLAC files
  FLAC_FILES_LIST="$temp_dir/flac_files_list"

  # Find all files with .flac extension (case-insensitive)
  # Then verify they're actually FLAC files using file magic bytes
  # This filters out Apple metadata files, corrupt files, etc.
  find "$SOURCE" -type f -iname "*.flac" -print0 | while IFS= read -r -d '' file; do
    # Check if file is actually a FLAC audio file using magic bytes
    if file -b "$file" | grep -q "FLAC audio"; then
      printf '%s\0' "$file"
    fi
  done >"$FLAC_FILES_LIST"

  # Count files
  TOTAL_FILES=$(tr -cd '\0' <"$FLAC_FILES_LIST" | wc -c | tr -d ' ')

  if [ "$TOTAL_FILES" -eq 0 ]; then
    warn "No valid FLAC files found in $SOURCE"
    warn "Found .flac files but none had valid FLAC audio format"
    exit 0
  fi

  success "Found $TOTAL_FILES FLAC files"
  echo ""
}

#==============================================================================
# CONVERSION FUNCTIONS
#==============================================================================

# Format seconds into human-readable time (e.g., "2m 30s" or "1h 15m")
format_time() {
  local seconds=$1
  local hours=$((seconds / 3600))
  local minutes=$(((seconds % 3600) / 60))
  local secs=$((seconds % 60))

  if [ $hours -gt 0 ]; then
    echo "${hours}h ${minutes}m"
  elif [ $minutes -gt 0 ]; then
    echo "${minutes}m ${secs}s"
  else
    echo "${secs}s"
  fi
}

# Background progress monitor
progress_monitor() {
  local total=$1
  local start=$2
  local update_interval=2 # Update every 2 seconds (reduced CPU usage)

  while true; do
    sleep $update_interval

    # Read current counts
    local success=$(cat "$success_file" 2>/dev/null || echo 0)
    local skipped=$(cat "$skipped_file" 2>/dev/null || echo 0)
    local failed=$(cat "$failed_file" 2>/dev/null || echo 0)

    # Processed = completed files (success + skipped + failed)
    local processed=$((success + skipped + failed))

    # Calculate progress (avoid division by zero)
    local percent=0
    if [ $total -gt 0 ]; then
      percent=$((processed * 100 / total))
    fi
    local elapsed=$(($(date +%s) - start))

    # Calculate ETA based on overall elapsed time, not per-file
    local eta="calculating..."
    if [ $processed -gt 0 ] && [ $elapsed -gt 2 ]; then
      local remaining=$((total - processed))
      if [ $remaining -gt 0 ]; then
        # ETA = (elapsed / processed) * remaining
        local eta_seconds=$(((elapsed * remaining) / processed))
        eta=$(format_time $eta_seconds)
      else
        eta="done"
      fi
    elif [ $processed -eq 0 ] && [ $elapsed -gt 5 ]; then
      eta="unknown"
    fi

    # Create progress bar (40 chars wide)
    local bar_width=40
    local filled=$((percent * bar_width / 100))
    local empty=$((bar_width - filled))
    local bar=""
    for ((i = 0; i < filled; i++)); do bar+="█"; done
    for ((i = 0; i < empty; i++)); do bar+="░"; done

    # Clear line completely and print progress bar
    # Use printf with dynamic width based on total file count
    local num_width=${#total} # Width needed for total number
    printf "\r\033[K${BLUE}[${bar}]${NC} %${num_width}d/%d (%2d%%) | ${GREEN}✓%-4d${NC} ${YELLOW}⊘%-4d${NC} ${RED}✗%-4d${NC} | ETA: %-15s" \
      "$processed" "$total" "$percent" "$success" "$skipped" "$failed" "$eta"

    # Exit if all files processed
    if [ $processed -ge $total ]; then
      echo "" # New line after final update
      break
    fi
  done
}

# Acquire a lock file with timeout
acquire_lock() {
  local lock_file="$1"
  local timeout=5
  local elapsed=0

  while ! mkdir "$lock_file" 2>/dev/null; do
    sleep 0.1
    elapsed=$((elapsed + 1))

    # Timeout after 5 seconds (50 iterations * 0.1s)
    if [ $elapsed -ge 50 ]; then
      # Check if lock is stale (older than timeout seconds)
      if [ -d "$lock_file" ]; then
        local lock_age=$(($(date +%s) - $(stat -f %m "$lock_file" 2>/dev/null || echo 0)))
        if [ $lock_age -gt $timeout ]; then
          # Remove stale lock
          rmdir "$lock_file" 2>/dev/null || true
          continue
        fi
      fi
      return 1
    fi
  done
  return 0
}

# Release a lock file
release_lock() {
  local lock_file="$1"
  rmdir "$lock_file" 2>/dev/null || true
}

# Atomically increment a counter file
increment_counter() {
  local file="$1"
  local lock_file="$file.lock"

  if ! acquire_lock "$lock_file"; then
    echo "Warning: Failed to acquire lock for $file" >&2
    return 1
  fi

  local count=$(($(cat "$file" 2>/dev/null || echo 0) + 1))
  echo "$count" >"$file"
  release_lock "$lock_file"
  echo "$count"
}

# Check if MP3 file appears to be valid (not partial/corrupt)
is_valid_mp3() {
  local file="$1"

  # Check if file exists and has non-zero size
  [ -f "$file" ] && [ -s "$file" ] || return 1

  # Fast validation: check MP3 header magic bytes (first 2-3 bytes)
  # Valid MP3 files start with 0xFF 0xFB, 0xFF 0xFA, or ID3 tag (0x49 0x44 0x33)
  local header=$(xxd -l 3 -p "$file" 2>/dev/null)

  # Check for MP3 frame sync (0xFFFA or 0xFFFB) or ID3v2 tag (494433)
  if [[ "$header" =~ ^fffa || "$header" =~ ^fffb || "$header" =~ ^494433 ]]; then
    # Also check minimum file size (valid MP3 should be at least 1KB)
    local size=$(stat -f %z "$file" 2>/dev/null || echo 0)
    [ $size -gt 1024 ] && return 0
  fi

  return 1
}

# Convert a single FLAC file to MP3
convert_file() {
  local file="$1"
  local total="$2"

  # Calculate destination path
  local rel_path="${file#$SOURCE/}"
  local dest_dir="$DEST/$(dirname "$rel_path")"
  local dest_file="$dest_dir/$(basename "${file%.flac}.mp3")"

  # Create destination directory with error checking
  if ! mkdir -p "$dest_dir" 2>/dev/null; then
    echo -e "${RED}✗ Failed to create directory: $dest_dir${NC}" >&2
    increment_counter "$failed_file" >/dev/null

    local lock_file="$failed_list.lock"
    acquire_lock "$lock_file"
    echo "$file" >>"$failed_list"
    release_lock "$lock_file"
    return 1
  fi

  # Atomic counter increment
  local current=$(increment_counter "$counter_file")
  local basename_file=$(basename "$file")

  # Check if file already exists and is valid
  if [ "$OVERWRITE_EXISTING" = false ] && [ -f "$dest_file" ]; then
    # Verify the existing file is valid
    if is_valid_mp3 "$dest_file"; then
      echo -e "${YELLOW}[$current/$total] Skipping (exists): $basename_file${NC}"
      increment_counter "$skipped_file" >/dev/null
      return 0
    else
      # Existing file is corrupt/partial, will be overwritten
      echo -e "${YELLOW}[$current/$total] Replacing corrupt file: $basename_file${NC}"
    fi
  fi

  echo -e "${BLUE}[$current/$total] Converting: $basename_file${NC}"

  # Create temporary output file to avoid partial writes
  local temp_output="${dest_file}.tmp.$"

  # Convert with ffmpeg (FFMPEG_QUALITY_ARGS intentionally unquoted for arg expansion)
  if ffmpeg -i "$file" $FFMPEG_QUALITY_ARGS -map_metadata 0 -id3v2_version 3 "$temp_output" -y -loglevel error 2>&1; then
    # Move temp file to final destination
    if mv "$temp_output" "$dest_file" 2>/dev/null; then
      echo -e "${GREEN}[$current/$total] ✓ Success: $basename_file${NC}"
      increment_counter "$success_file" >/dev/null
    else
      echo -e "${RED}[$current/$total] ✗ Failed to move output: $basename_file${NC}"
      rm -f "$temp_output" 2>/dev/null
      increment_counter "$failed_file" >/dev/null

      local lock_file="$failed_list.lock"
      acquire_lock "$lock_file"
      echo "$file" >>"$failed_list"
      release_lock "$lock_file"
    fi
  else
    echo -e "${RED}[$current/$total] ✗ Conversion failed: $basename_file${NC}"
    rm -f "$temp_output" 2>/dev/null
    increment_counter "$failed_file" >/dev/null

    local lock_file="$failed_list.lock"
    acquire_lock "$lock_file"
    echo "$file" >>"$failed_list"
    release_lock "$lock_file"
  fi
}

# Generate the wrapper script with all functions inlined
# This wrapper is called by xargs for each file conversion
# NOTE: Functions are duplicated here (not sourced) because xargs spawns separate
# processes that don't inherit function definitions from the parent shell
generate_wrapper_script() {
  local wrapper_path="$1"

  cat >"$wrapper_path" <<'WRAPPER_EOF'
#!/bin/bash
# Auto-generated wrapper script for parallel FLAC to MP3 conversion
# This script contains all necessary functions and is called once per file by xargs

# Lock management functions
acquire_lock() {
    local lock_file="$1"
    local timeout=5
    local elapsed=0
    
    while ! mkdir "$lock_file" 2>/dev/null; do
        sleep 0.1
        elapsed=$((elapsed + 1))
        if [ $elapsed -ge 50 ]; then
            if [ -d "$lock_file" ]; then
                local lock_age=$(($(date +%s) - $(stat -f %m "$lock_file" 2>/dev/null || echo 0)))
                if [ $lock_age -gt $timeout ]; then
                    rmdir "$lock_file" 2>/dev/null || true
                    continue
                fi
            fi
            return 1
        fi
    done
    return 0
}

release_lock() {
    local lock_file="$1"
    rmdir "$lock_file" 2>/dev/null || true
}

increment_counter() {
    local file="$1"
    local lock_file="$file.lock"
    
    if ! acquire_lock "$lock_file"; then
        echo "Warning: Failed to acquire lock for $file" >&2
        return 1
    fi
    
    local count=$(($(cat "$file" 2>/dev/null || echo 0) + 1))
    echo "$count" > "$file"
    release_lock "$lock_file"
    echo "$count"
}

is_valid_mp3() {
    local file="$1"
    [ -f "$file" ] && [ -s "$file" ] || return 1
    local header=$(xxd -l 3 -p "$file" 2>/dev/null)
    if [[ "$header" =~ ^fffa || "$header" =~ ^fffb || "$header" =~ ^494433 ]]; then
        local size=$(stat -f %z "$file" 2>/dev/null || echo 0)
        [ $size -gt 1024 ] && return 0
    fi
    return 1
}

convert_file() {
    local file="$1"
    local total="$2"
    local rel_path="${file#$SOURCE/}"
    local dest_dir="$DEST/$(dirname "$rel_path")"
    local dest_file="$dest_dir/$(basename "${file%.flac}.mp3")"
    local basename_file=$(basename "$file")
    
    # Check dry-run mode via file flag
    local is_dry_run=false
    [ -f "$dry_run_file" ] && is_dry_run=true
    
    # Dry-run mode: show only files that would be converted
    if [ "$is_dry_run" = true ]; then
        if [ "$OVERWRITE_EXISTING" = false ] && [ -f "$dest_file" ] && is_valid_mp3 "$dest_file"; then
            # File exists and is valid - skip silently
            increment_counter "$skipped_file" > /dev/null
        else
            # File would be converted - show it
            echo "$file"
            increment_counter "$success_file" > /dev/null
        fi
        return 0
    fi
    
    if ! mkdir -p "$dest_dir" 2>/dev/null; then
        echo -e "${RED}✗ Failed to create directory: $dest_dir${NC}" >&2
        increment_counter "$failed_file" > /dev/null
        acquire_lock "$failed_list.lock"
        echo "$file" >> "$failed_list"
        release_lock "$failed_list.lock"
        return 1
    fi
    
    if [ "$OVERWRITE_EXISTING" = false ] && [ -f "$dest_file" ]; then
        if is_valid_mp3 "$dest_file"; then
            increment_counter "$skipped_file" > /dev/null
            return 0
        fi
    fi
    
    # Create temp file with .mp3 extension for ffmpeg
    # ffmpeg requires the output filename to have the correct extension
    # to determine the output format (it can't infer MP3 from a random temp name)
    local temp_output=$(mktemp "${dest_file}.tmp.XXXXXX")
    if [ $? -ne 0 ]; then
        echo -e "${RED}✗ Failed to create temp file: $basename_file${NC}" >&2
        increment_counter "$failed_file" > /dev/null
        return 1
    fi
    mv "$temp_output" "${temp_output}.mp3"
    temp_output="${temp_output}.mp3"
    
    # Capture ffmpeg errors to a temp file
    local ffmpeg_errors=$(mktemp)
    if [ $? -ne 0 ]; then
        echo -e "${RED}✗ Failed to create error log: $basename_file${NC}" >&2
        rm -f "$temp_output" 2>/dev/null
        increment_counter "$failed_file" > /dev/null
        return 1
    fi
    
    if ffmpeg -i "$file" $FFMPEG_QUALITY_ARGS -map_metadata 0 -id3v2_version 3 "$temp_output" -y 2>"$ffmpeg_errors"; then
        if mv "$temp_output" "$dest_file" 2>/dev/null; then
            increment_counter "$success_file" > /dev/null
            rm -f "$ffmpeg_errors"
        else
            echo -e "${RED}✗ Failed to move: $basename_file${NC}" >&2
            rm -f "$temp_output" "$ffmpeg_errors" 2>/dev/null
            increment_counter "$failed_file" > /dev/null
            
            # Log the error
            if acquire_lock "$error_log.lock"; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Failed to move output: $file" >> "$error_log"
                echo "  Could not move temporary file to destination" >> "$error_log"
                echo "" >> "$error_log"
                release_lock "$error_log.lock"
            fi
            
            if acquire_lock "$failed_list.lock"; then
                echo "$file" >> "$failed_list"
                release_lock "$failed_list.lock"
            fi
        fi
    else
        echo -e "${RED}✗ Conversion failed: $basename_file${NC}" >&2
        rm -f "$temp_output" 2>/dev/null
        increment_counter "$failed_file" > /dev/null
        
        # Log the error with ffmpeg output
        if acquire_lock "$error_log.lock"; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Conversion failed: $file" >> "$error_log"
            echo "ffmpeg error output:" >> "$error_log"
            sed 's/^/  /' "$ffmpeg_errors" >> "$error_log"
            echo "" >> "$error_log"
            release_lock "$error_log.lock"
        fi
        
        if acquire_lock "$failed_list.lock"; then
            echo "$file" >> "$failed_list"
            release_lock "$failed_list.lock"
        fi
        
        rm -f "$ffmpeg_errors"
    fi
}

# Execute conversion
convert_file "$1" "$2"
WRAPPER_EOF

  chmod +x "$wrapper_path"
}

# Run parallel conversion of all FLAC files
run_conversion() {
  local wrapper_script="$temp_dir/convert_wrapper.sh"

  # Generate the wrapper script
  generate_wrapper_script "$wrapper_script"

  # Export all variables
  export SOURCE DEST BITRATE_ARG FFMPEG_QUALITY_ARGS OVERWRITE_EXISTING
  export success_file skipped_file failed_file failed_list dry_run_file error_log
  export RED GREEN YELLOW BLUE NC TOTAL_FILES

  if [ "$DRY_RUN" = true ]; then
    info "DRY RUN - Listing files that would be converted..."
    touch "$dry_run_file"
  else
    info "Starting conversion..."
  fi
  echo ""

  # In dry-run mode, don't start progress monitor
  if [ "$DRY_RUN" = false ]; then
    start_time=$(date +%s)
    progress_monitor "$TOTAL_FILES" "$start_time" &
    monitor_pid=$!
  fi

  cat "$FLAC_FILES_LIST" |
    xargs -0 -P "$PARALLEL_JOBS" -I {} "$wrapper_script" {} "$TOTAL_FILES"

  # Wait for progress monitor to finish (only if running)
  if [ "$monitor_pid" -gt 0 ] 2>/dev/null; then
    wait "$monitor_pid" 2>/dev/null
    monitor_pid=0
  fi

  echo ""
}

#==============================================================================
# REPORTING FUNCTIONS
#==============================================================================

# Display configuration before starting
show_configuration() {
  if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}MODE: DRY RUN (no files will be converted)${NC}"
  fi
  echo -e "${YELLOW}Source:${NC} $SOURCE"
  echo -e "${YELLOW}Destination:${NC} $DEST"
  echo -e "${YELLOW}Encoding:${NC} $BITRATE_MODE $BITRATE_ARG"
  echo -e "${YELLOW}Parallel jobs:${NC} $PARALLEL_JOBS"
  echo ""
}

# Print final conversion summary
print_summary() {
  local success_count=$(cat "$success_file")
  local skipped_count=$(cat "$skipped_file")
  local failed_count=$(cat "$failed_file")

  echo ""
  if [ "$DRY_RUN" = true ]; then
    echo -e "${BLUE}Dry Run Complete${NC}"
  else
    echo -e "${BLUE}Conversion Complete${NC}"
  fi
  echo ""

  if [ "$DRY_RUN" = true ]; then
    echo -e "${GREEN}✓ Would convert: $success_count${NC}"
  else
    echo -e "${GREEN}✓ Successfully converted: $success_count${NC}"
  fi

  if [ "$skipped_count" -gt 0 ]; then
    if [ "$DRY_RUN" = true ]; then
      echo -e "${YELLOW}⊘ Would skip (already exist): $skipped_count${NC}"
    else
      echo -e "${YELLOW}⊘ Skipped (already exist): $skipped_count${NC}"
    fi
  fi

  if [ "$failed_count" -gt 0 ]; then
    echo -e "${RED}✗ Failed: $failed_count${NC}"
    echo ""
    echo -e "${RED}Failed files:${NC}"
    cat "$failed_list"

    # Copy error log to destination for review
    if [ -s "$error_log" ]; then
      local final_error_log="$DEST/conversion_errors.log"
      cp "$error_log" "$final_error_log"
      echo ""
      echo -e "${YELLOW}Detailed error log saved to:${NC} $final_error_log"
    fi
  fi

  echo ""
  if [ "$DRY_RUN" = false ]; then
    echo -e "${YELLOW}Output directory:${NC} $DEST"
  fi
}

# Ask user for confirmation before proceeding
confirm_conversion() {
  if [ "$DRY_RUN" = true ]; then
    # No confirmation needed for dry run
    return 0
  fi

  read -p "Proceed with conversion? (y/n): " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    warn "Conversion cancelled"
    exit 0
  fi
}

#==============================================================================
# MAIN EXECUTION
#==============================================================================

# Show usage information
show_usage() {
  cat <<EOF
Usage: $0 [OPTIONS] <source_directory> <destination_directory>

Options:
  --dry-run            Test run without converting files
  --bitrate, -b RATE   MP3 bitrate (default: 320k)
                       CBR: 320k, 256k, 192k, 128k
                       VBR: V0 (best), V2 (high), V4 (medium), V6 (acceptable)
  --overwrite          Overwrite existing MP3 files (default: skip existing)

Arguments:
  source_directory      - Directory containing FLAC files
  destination_directory - Where to save converted MP3s

Examples:
  $0 /Volumes/MyDrive/Music ~/Desktop/Converted_MP3s
  $0 --bitrate 256k ~/Music ~/Desktop/MP3s
  $0 -b V0 ~/Music ~/Desktop/MP3s
  $0 --dry-run --bitrate V2 ~/Music ~/Desktop/MP3s
  $0 ~/Music ~/Desktop/MP3s --dry-run -b 192k --overwrite
EOF
  exit 1
}

# Parse command-line arguments
parse_arguments() {
  local positional_args=()

  # Parse flags and options
  while [[ "$#" -gt 0 ]]; do
    case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --overwrite)
      OVERWRITE_EXISTING=true
      shift
      ;;
    --bitrate | -b)
      if [ -z "$2" ] || [[ "$2" == --* ]]; then
        error_exit "Option $1 requires an argument"
      fi
      BITRATE_ARG="$2"
      shift 2
      ;;
    -*)
      error_exit "Unknown option: $1"
      ;;
    *)
      positional_args+=("$1")
      shift
      ;;
    esac
  done

  # Validate we have required positional arguments
  if [ "${#positional_args[@]}" -lt 2 ]; then
    show_usage
  fi

  # Set global variables
  SOURCE="${positional_args[0]}"
  DEST="${positional_args[1]}"
  BITRATE_ARG="${BITRATE_ARG:-$DEFAULT_BITRATE}"
}

main() {
  # Parse command-line arguments
  parse_arguments "$@"

  # Validate inputs
  check_dependencies
  validate_bitrate "$BITRATE_ARG"
  validate_directories "$SOURCE" "$DEST"

  # Setup environment
  setup_parallel_jobs
  setup_temp_files

  # Find files and check space
  find_and_count_flac_files

  # Skip disk space check for dry-run
  if [ "$DRY_RUN" = false ]; then
    check_disk_space
  fi

  # Display configuration
  show_configuration

  # Confirm and execute
  confirm_conversion
  run_conversion

  # Report results
  print_summary
}

# Run main function
main "$@"
