#!/bin/bash
# ABOUTME: API abstraction layer for multiple providers (Gemini, OpenRouter)

# Source the appropriate provider wrapper based on configuration
init_api_wrapper() {
    local api_provider="${API_PROVIDER:-gemini}"
    
    debug_log 1 "Initializing API wrapper with provider: $api_provider"
    
    case "$api_provider" in
        "gemini")
            source "$(dirname "$0")/lib/gemini-wrapper.sh"
            if ! init_gemini_wrapper; then
                error_log "Failed to initialize Gemini wrapper"
                return 1
            fi
            ;;
        "openrouter")
            source "$(dirname "$0")/lib/openrouter-wrapper.sh"
            if ! init_openrouter_wrapper; then
                error_log "Failed to initialize OpenRouter wrapper"
                return 1
            fi
            ;;
        *)
            error_log "Unknown API provider: $api_provider"
            return 1
            ;;
    esac
    
    debug_log 1 "API wrapper initialized successfully with $api_provider"
    return 0
}

# Unified API call function
call_api() {
    local tool_type="$1"
    local files="$2"
    local working_dir="$3"
    local original_prompt="$4"
    local api_provider="${API_PROVIDER:-gemini}"
    
    debug_log 2 "Calling API provider: $api_provider"
    
    case "$api_provider" in
        "gemini")
            call_gemini "$tool_type" "$files" "$working_dir" "$original_prompt"
            ;;
        "openrouter")
            call_openrouter "$tool_type" "$files" "$working_dir" "$original_prompt"
            ;;
        *)
            error_log "Unknown API provider: $api_provider"
            return 1
            ;;
    esac
}

# Get provider-specific limits
get_api_limits() {
    local api_provider="${API_PROVIDER:-gemini}"
    local limit_type="$1"  # token_limit, max_files, max_size
    
    case "$api_provider" in
        "gemini")
            case "$limit_type" in
                "token_limit") echo "${GEMINI_TOKEN_LIMIT:-800000}" ;;
                "max_files") echo "${GEMINI_MAX_FILES:-20}" ;;
                "max_size") echo "${MAX_TOTAL_SIZE_FOR_GEMINI:-10485760}" ;;
                *) echo "0" ;;
            esac
            ;;
        "openrouter")
            case "$limit_type" in
                "token_limit") echo "${OPENROUTER_MAX_TOKENS:-100000}" ;;
                "max_files") echo "${OPENROUTER_MAX_FILES:-20}" ;;
                "max_size") echo "${MAX_TOTAL_SIZE_FOR_GEMINI:-10485760}" ;;  # Reuse same limit
                *) echo "0" ;;
            esac
            ;;
        *)
            echo "0"
            ;;
    esac
}

# Get provider name for logging
get_api_provider_name() {
    local api_provider="${API_PROVIDER:-gemini}"
    
    case "$api_provider" in
        "gemini") echo "Gemini" ;;
        "openrouter") echo "OpenRouter" ;;
        *) echo "Unknown" ;;
    esac
}

# Clean up provider cache
cleanup_api_cache() {
    local api_provider="${API_PROVIDER:-gemini}"
    local max_age_hours="${1:-24}"
    
    case "$api_provider" in
        "gemini")
            cleanup_gemini_cache "$max_age_hours"
            ;;
        "openrouter")
            cleanup_openrouter_cache "$max_age_hours"
            ;;
        *)
            error_log "Unknown API provider for cache cleanup: $api_provider"
            ;;
    esac
}

# Test function for API wrapper
test_api_wrapper() {
    echo "Testing API wrapper..."
    local failed=0
    
    # Test 1: Initialization with default (Gemini)
    API_PROVIDER="gemini"
    if ! init_api_wrapper; then
        echo "❌ Test 1 failed: API wrapper initialization with Gemini"
        failed=1
    else
        echo "✅ Test 1 passed: API wrapper initialization with Gemini"
    fi
    
    # Test 2: Get limits
    local token_limit=$(get_api_limits "token_limit")
    if [ "$token_limit" -eq 0 ]; then
        echo "❌ Test 2 failed: Get API limits"
        failed=1
    else
        echo "✅ Test 2 passed: Get API limits (token_limit: $token_limit)"
    fi
    
    # Test 3: Provider name
    local provider_name=$(get_api_provider_name)
    if [ "$provider_name" != "Gemini" ]; then
        echo "❌ Test 3 failed: Get provider name"
        failed=1
    else
        echo "✅ Test 3 passed: Get provider name ($provider_name)"
    fi
    
    # Test 4: Switch to OpenRouter (if API key is set)
    if [ -n "$OPENROUTER_API_KEY" ]; then
        API_PROVIDER="openrouter"
        if ! init_api_wrapper; then
            echo "❌ Test 4 failed: API wrapper initialization with OpenRouter"
            failed=1
        else
            echo "✅ Test 4 passed: API wrapper initialization with OpenRouter"
        fi
    else
        echo "⚠️  Test 4 skipped: OpenRouter API key not set"
    fi
    
    if [ $failed -eq 0 ]; then
        echo "🎉 All API wrapper tests passed!"
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
        init_debug "api-wrapper-test"
    fi
    
    test_api_wrapper
fi