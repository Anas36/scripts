#!/bin/bash

# Function to check connectivity using nc
check_connectivity() {
    local ip="$1"
    local port="$2"
    if nc -z -w 1 "$ip" "$port"; then
        echo "Success"
    else
        echo "Failed"
    fi
}

# Check if the user has provided the input and output filenames
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <Input_File> <Output_File>"
    exit 1
fi

input_filename="$1"
output_filename="$2"

# Process each line in the input file and write results to the output file
while IFS= read -r line; do
    ip=$(echo "$line" | awk '{print $1}')
    ports=$(echo "$line" | awk '{print $2}' | tr '/' ' ')
    
    for port in $ports; do
        # Check connectivity
        status=$(check_connectivity "$ip" "$port")

        if [ "$status" == "Success" ]; then
            echo "Connectivity to $ip:$port is successful." >> "$output_filename"
        else
            echo "Connectivity to $ip:$port has failed." >> "$output_filename"
        fi
    done
done < "$input_filename"

echo "Results saved in $output_filename."

#run this script by ./check_connectivity_to_file.sh input.txt output.txt
