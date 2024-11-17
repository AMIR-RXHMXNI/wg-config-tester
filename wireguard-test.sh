#!/bin/bash

# Enable error handling
set -uo pipefail

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (sudo)"
    exit 1
fi

# Check if wireguard is installed
if ! command -v wg &> /dev/null; then
    echo "Wireguard is not installed. Please install it first."
    exit 1
fi

# Debug function
debug_config() {
    local config_file="$1"
    echo "=== Debugging Config: $config_file ==="
    
    # Check file permissions
    echo "File permissions:"
    ls -l "$config_file"
    
    # Check file contents (excluding private keys)
    echo -e "\nConfig file contents (excluding private keys):"
    grep -v "PrivateKey" "$config_file" || true
    
    # Check if file has correct line endings
    if file "$config_file" | grep -q "CRLF"; then
        echo -e "\nWarning: File has Windows-style line endings. Converting..."
        dos2unix "$config_file"
    fi
    
    # Check basic config structure
    echo -e "\nChecking config structure:"
    if ! grep -q "\[Interface\]" "$config_file"; then
        echo "Error: Missing [Interface] section"
    fi
    if ! grep -q "\[Peer\]" "$config_file"; then
        echo "Error: Missing [Peer] section"
    fi
    if ! grep -q "^Address" "$config_file"; then
        echo "Error: Missing Address field"
    fi
}

# Test interface function with detailed error reporting
test_interface() {
    local config_file="$1"
    local interface_name=$(basename "$config_file" .conf)
    local result
    
    echo "=== Testing Interface: $interface_name ==="
    
    # Check if interface exists before starting
    if ip link show "$interface_name" &>/dev/null; then
        echo "Interface already exists, cleaning up..."
        wg-quick down "$interface_name" 2>&1
        sleep 2
    fi
    
    # Try to bring up interface with full error output
    echo "Attempting to bring up interface..."
    result=$(wg-quick up "$config_file" 2>&1)
    if [ $? -ne 0 ]; then
        echo "Failed to bring up interface. Error output:"
        echo "$result"
        # Check for common issues in the error output
        if echo "$result" | grep -q "Error: \`(([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}\|[a-f0-9:]{2,4}(:[a-f0-9:]{2,4})*(/[0-9]{1,3})?)\`"; then
            echo "Issue detected: Invalid IP address format in config"
        fi
        if echo "$result" | grep -q "RTNETLINK"; then
            echo "Issue detected: Network interface problem (RTNETLINK error)"
        fi
        if echo "$result" | grep -q "Permission denied"; then
            echo "Issue detected: Permission problem"
        fi
        return 1
    fi
    
    # If interface is up, check its status
    echo -e "\nInterface details:"
    wg show "$interface_name" || true
    ip addr show "$interface_name" || true
    
    return 0
}

# Main script
main() {
    local configs_dir="${1:-./configs}"
    local working_dir="$configs_dir/working_configs"
    local log_file="$configs_dir/test_results.log"
    
    # Create working configs directory
    mkdir -p "$working_dir"
    
    # Initialize log file
    echo "Wireguard Config Test Results - $(date)" > "$log_file"
    
    # Process each config file
    find "$configs_dir" -maxdepth 1 -type f -name "*.conf" -print0 | while IFS= read -r -d '' config_file; do
        echo "===============================================" | tee -a "$log_file"
        echo "Processing: $config_file" | tee -a "$log_file"
        
        # Debug the config
        debug_config "$config_file" 2>&1 | tee -a "$log_file"
        
        # Test the interface
        if test_interface "$config_file" 2>&1 | tee -a "$log_file"; then
            echo "SUCCESS: Config works" | tee -a "$log_file"
            cp "$config_file" "$working_dir/"
        else
            echo "FAILED: Config does not work" | tee -a "$log_file"
        fi
        
        # Clean up interface if it exists
        interface_name=$(basename "$config_file" .conf)
        if ip link show "$interface_name" &>/dev/null; then
            wg-quick down "$interface_name" 2>&1 | tee -a "$log_file"
        fi
        
        echo "-----------------------------------------------" | tee -a "$log_file"
    done
}

# Show help if requested
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    echo "Usage: $0 [configs_directory]"
    echo "If configs_directory is not specified, ./configs will be used"
    exit 0
fi

# Run the main function
main "$@"
