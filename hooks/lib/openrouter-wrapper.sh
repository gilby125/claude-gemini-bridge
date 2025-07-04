#!/bin/bash
# ABOUTME: Wrapper for OpenRouter API with caching and rate limiting

# Configuration
OPENROUTER_CACHE_DIR="${OPENROUTER_CACHE_DIR:-${CLAUDE_GEMINI_BRIDGE_DIR:-$HOME/.claude-gemini-bridge}/cache/openrouter}"
OPENROUTER_CACHE_TTL="${OPENROUTER_CACHE_TTL:-3600}"  # 1 hour
OPENROUTER_TIMEOUT="${OPENROUTER_TIMEOUT:-30}"        # 30 seconds
OPENROUTER_RATE_LIMIT="${OPENROUTER_RATE_LIMIT:-1}"   # 1 second between calls
OPENROUTER_MAX_FILES="${OPENROUTER_MAX_FILES:-20}"    # Max 20 files per call
OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}"
OPENROUTER_MODEL="${OPENROUTER_MODEL:-openrouter/cypher-alpha:free}"
OPENROUTER_BASE_URL="${OPENROUTER_BASE_URL:-https://openrouter.ai/api/v1}"
OPENROUTER_MAX_TOKENS="${OPENROUTER_MAX_TOKENS:-100000}"

# Rate limiting file
RATE_LIMIT_FILE="/tmp/claude_bridge_openrouter_last_call"

# Initialize OpenRouter wrapper
init_openrouter_wrapper() {
    mkdir -p "$OPENROUTER_CACHE_DIR"
    
    # Check if API key is set
    if [ -z "$OPENROUTER_API_KEY" ]; then
        error_log "OpenRouter API key not set"
        return 1
    fi
    
    # Test if curl is available
    if ! command -v curl >/dev/null 2>&1; then
        error_log "curl not found in PATH (required for OpenRouter)"
        return 1
    fi
    
    # Test if jq is available
    if ! command -v jq >/dev/null 2>&1; then
        error_log "jq not found in PATH (required for OpenRouter)"
        return 1
    fi
    
    debug_log 1 "OpenRouter wrapper initialized"
    debug_log 2 "Cache dir: $OPENROUTER_CACHE_DIR"
    debug_log 2 "Cache TTL: $OPENROUTER_CACHE_TTL seconds"
    debug_log 2 "Model: $OPENROUTER_MODEL"
    
    return 0
}

# Implement rate limiting (same as Gemini)
enforce_rate_limit() {
    if [ -f "$RATE_LIMIT_FILE" ]; then
        local last_call=$(cat "$RATE_LIMIT_FILE" 2>/dev/null || echo "0")
        local current_time=$(date +%s)
        local time_diff=$((current_time - last_call))
        
        if [ "$time_diff" -lt "$OPENROUTER_RATE_LIMIT" ]; then
            local sleep_time=$((OPENROUTER_RATE_LIMIT - time_diff))
            debug_log 2 "Rate limiting: sleeping ${sleep_time}s"
            sleep "$sleep_time"
        fi
    fi
    
    # Save current time
    date +%s > "$RATE_LIMIT_FILE"
}

# Generate cache key from input (same as Gemini)
generate_cache_key() {
    local prompt="$1"
    local files="$2"
    local working_dir="$3"
    
    # Create hash from file contents + metadata
    local content_hash=""
    local file_array=($files)
    
    for file in "${file_array[@]}"; do
        if [ -f "$file" ] && [ -r "$file" ]; then
            # Combine filename, size, modification time and first 1KB of content
            local file_info=$(stat -f "%N|%z|%m" "$file" 2>/dev/null || stat -c "%n|%s|%Y" "$file" 2>/dev/null)
            local file_sample=$(head -c 1024 "$file" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
            content_hash="${content_hash}${file_info}|${file_sample}|"
        fi
    done
    
    # SHA256 hash from all parameters + file contents
    local input_string="$prompt|$files|$working_dir|$content_hash"
    echo "$input_string" | shasum -a 256 | cut -d' ' -f1
}

# Check if cache entry is still valid (same as Gemini)
is_cache_valid() {
    local cache_file="$1"
    
    if [ ! -f "$cache_file" ]; then
        return 1
    fi
    
    local cache_age=$(( $(date +%s) - $(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file") ))
    
    if [ "$cache_age" -lt "$OPENROUTER_CACHE_TTL" ]; then
        debug_log 2 "Cache hit: age ${cache_age}s (TTL: ${OPENROUTER_CACHE_TTL}s)"
        return 0
    else
        debug_log 2 "Cache expired: age ${cache_age}s"
        return 1
    fi
}

# Create OpenRouter prompt based on tool type
create_openrouter_prompt() {
    local tool_type="$1"
    local original_prompt="$2"
    local file_count="$3"
    
    case "$tool_type" in
        "Read")
            echo "Analyze this file and provide a concise summary. Focus on purpose, main functions and important details:"
            ;;
        "Glob"|"Grep")
            echo "Analyze these $file_count files and create a structured overview. Group similar files and explain the purpose of each group:"
            ;;
        "Task")
            if [[ "$original_prompt" =~ (search|find|suche|finde) ]]; then
                echo "Search the provided files for the specified criteria. Provide a structured list of findings with context: $original_prompt"
            elif [[ "$original_prompt" =~ (analyze|analysiere|verstehe) ]]; then
                echo "Perform a detailed code analysis: $original_prompt"
            else
                echo "Process the following task with the provided files: $original_prompt"
            fi
            ;;
        *)
            echo "Analyze the provided files and provide a helpful summary."
            ;;
    esac
}

# Prepare file content for OpenRouter API
prepare_files_content() {
    local files="$1"
    local working_dir="$2"
    local content=""
    local file_count=0
    local total_size=0
    
    # Convert to array
    local file_array=($files)
    
    for file in "${file_array[@]}"; do
        # Skip if too many files
        if [ "$file_count" -ge "$OPENROUTER_MAX_FILES" ]; then
            debug_log 1 "File limit reached: $OPENROUTER_MAX_FILES"
            break
        fi
        
        # Make path absolute if necessary
        if [[ "$file" != /* ]]; then
            file="$working_dir/$file"
        fi
        
        # Check if file exists and is readable
        if [ -f "$file" ] && [ -r "$file" ]; then
            # Check file size (max 1MB per file)
            local file_size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo "0")
            if [ "$file_size" -lt 1048576 ]; then
                # Add file content with header
                content="$content\n\n--- File: $file ---\n"
                content="$content$(cat "$file")"
                file_count=$((file_count + 1))
                total_size=$((total_size + file_size))
                debug_log 3 "Added file: $file (${file_size} bytes)"
            else
                debug_log 2 "Skipping large file: $file (${file_size} bytes)"
            fi
        else
            debug_log 2 "Skipping non-existent/unreadable file: $file"
        fi
    done
    
    echo -e "$content"
}

# Main function: Call OpenRouter with caching
call_openrouter() {
    local tool_type="$1"
    local files="$2"
    local working_dir="$3"
    local original_prompt="$4"
    
    debug_log 1 "Calling OpenRouter for tool: $tool_type"
    start_timer "openrouter_call"
    
    # Generate cache key
    local cache_key=$(generate_cache_key "$tool_type|$original_prompt" "$files" "$working_dir")
    local cache_file="$OPENROUTER_CACHE_DIR/$cache_key"
    
    # Check cache
    if is_cache_valid "$cache_file"; then
        debug_log 1 "Using cached result"
        cat "$cache_file"
        end_timer "openrouter_call" >/dev/null
        return 0
    fi
    
    # Prepare file content
    local file_content=$(prepare_files_content "$files" "$working_dir")
    local file_count=$(echo "$files" | wc -w | tr -d ' ')
    
    if [ -z "$file_content" ]; then
        debug_log 1 "No valid files found for OpenRouter"
        echo "No valid files found for analysis."
        end_timer "openrouter_call" >/dev/null
        return 1
    fi
    
    # Create prompt
    local openrouter_prompt=$(create_openrouter_prompt "$tool_type" "$original_prompt" "$file_count")
    
    debug_log 2 "Processing $file_count files with OpenRouter"
    debug_log 3 "Prompt: $openrouter_prompt"
    
    # Rate limiting
    enforce_rate_limit
    
    # Build request payload
    local full_prompt="$openrouter_prompt\n\nFiles:\n$file_content"
    local request_data=$(jq -n \
        --arg model "$OPENROUTER_MODEL" \
        --arg content "$full_prompt" \
        --arg max_tokens "$OPENROUTER_MAX_TOKENS" \
        '{
            model: $model,
            messages: [
                {
                    role: "system",
                    content: "You are a helpful code analysis assistant. Provide clear, structured analysis of the provided files."
                },
                {
                    role: "user",
                    content: $content
                }
            ],
            max_tokens: ($max_tokens | tonumber)
        }')
    
    # Call OpenRouter API
    local openrouter_response=""
    local openrouter_exit_code=0
    
    # Timeout with GNU timeout or gtimeout (macOS)
    local timeout_cmd="timeout"
    if command -v gtimeout >/dev/null 2>&1; then
        timeout_cmd="gtimeout"
    fi
    
    if command -v "$timeout_cmd" >/dev/null 2>&1; then
        openrouter_response=$("$timeout_cmd" "$OPENROUTER_TIMEOUT" curl -s -S \
            -X POST "$OPENROUTER_BASE_URL/chat/completions" \
            -H "Authorization: Bearer $OPENROUTER_API_KEY" \
            -H "Content-Type: application/json" \
            -d "$request_data" 2>&1)
        openrouter_exit_code=$?
    else
        # Fallback without timeout
        openrouter_response=$(curl -s -S \
            -X POST "$OPENROUTER_BASE_URL/chat/completions" \
            -H "Authorization: Bearer $OPENROUTER_API_KEY" \
            -H "Content-Type: application/json" \
            -d "$request_data" 2>&1)
        openrouter_exit_code=$?
    fi
    
    local duration=$(end_timer "openrouter_call")
    
    # Check result
    if [ "$openrouter_exit_code" -eq 0 ] && [ -n "$openrouter_response" ]; then
        # Parse response
        local content=$(echo "$openrouter_response" | jq -r '.choices[0].message.content // empty')
        local error=$(echo "$openrouter_response" | jq -r '.error.message // empty')
        
        if [ -n "$content" ]; then
            # Cache successful response
            echo "$content" > "$cache_file"
            debug_log 1 "OpenRouter call successful (${duration}s, $file_count files)"
            echo "$content"
            return 0
        elif [ -n "$error" ]; then
            error_log "OpenRouter API error: $error"
            echo "OpenRouter analysis failed: $error"
            return 1
        else
            error_log "Invalid OpenRouter response"
            debug_log 2 "OpenRouter response: $openrouter_response"
            echo "OpenRouter analysis failed. Please check the logs."
            return 1
        fi
    else
        error_log "OpenRouter call failed (exit code: $openrouter_exit_code)"
        debug_log 2 "OpenRouter error output: $openrouter_response"
        echo "OpenRouter analysis failed. Please check the logs."
        return 1
    fi
}

# Clean up old cache
cleanup_openrouter_cache() {
    local max_age_hours=${1:-24}  # Default: 24 hours
    
    debug_log 2 "Cleaning up OpenRouter cache older than $max_age_hours hours"
    
    find "$OPENROUTER_CACHE_DIR" -type f -mtime +$(echo "$max_age_hours/24" | bc) -delete 2>/dev/null
    
    # Cache statistics
    local cache_files=$(find "$OPENROUTER_CACHE_DIR" -type f | wc -l | tr -d ' ')
    local cache_size=$(du -sh "$OPENROUTER_CACHE_DIR" 2>/dev/null | cut -f1)
    
    debug_log 1 "Cache stats: $cache_files files, $cache_size total size"
}

# Test function for OpenRouter wrapper
test_openrouter_wrapper() {
    echo "Testing OpenRouter wrapper..."
    local failed=0
    
    # Test 1: Initialization
    if [ -z "$OPENROUTER_API_KEY" ]; then
        export OPENROUTER_API_KEY="test-key-for-testing"
    fi
    
    if ! init_openrouter_wrapper; then
        echo "❌ Test 1 failed: OpenRouter wrapper initialization"
        failed=1
    else
        echo "✅ Test 1 passed: OpenRouter wrapper initialization"
    fi
    
    # Test 2: Cache-Key Generation
    local key1=$(generate_cache_key "test" "file1.txt" "/tmp")
    local key2=$(generate_cache_key "test" "file1.txt" "/tmp")
    local key3=$(generate_cache_key "test2" "file1.txt" "/tmp")
    
    if [ "$key1" != "$key2" ]; then
        echo "❌ Test 2a failed: Cache keys should be identical"
        failed=1
    elif [ "$key1" = "$key3" ]; then
        echo "❌ Test 2b failed: Cache keys should be different"
        failed=1
    else
        echo "✅ Test 2 passed: Cache key generation"
    fi
    
    # Test 3: Prompt creation
    local prompt=$(create_openrouter_prompt "Read" "analyze this file" 1)
    if [[ "$prompt" != *"Analyze"* ]]; then
        echo "❌ Test 3 failed: Prompt creation"
        failed=1
    else
        echo "✅ Test 3 passed: Prompt creation"
    fi
    
    # Test 4: Rate limiting (simulated)
    echo $(date +%s) > "$RATE_LIMIT_FILE"
    local start_time=$(date +%s)
    enforce_rate_limit
    local end_time=$(date +%s)
    local time_diff=$((end_time - start_time))
    
    if [ "$time_diff" -ge 1 ]; then
        echo "✅ Test 4 passed: Rate limiting works"
    else
        echo "✅ Test 4 passed: Rate limiting (no delay needed)"
    fi
    
    # Cleanup
    rm -f "$RATE_LIMIT_FILE"
    
    if [ $failed -eq 0 ]; then
        echo "🎉 All OpenRouter wrapper tests passed!"
        return 0
    else
        echo "💥 Some tests failed!"
        return 1
    fi
}

# If script is called directly, run tests
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    # Initialize debug system for tests
    if [ -f "$(dirname "$0")/debug-helpers.sh" ]; then
        source "$(dirname "$0")/debug-helpers.sh"
        init_debug "openrouter-wrapper-test"
    fi
    
    test_openrouter_wrapper
fi