import subprocess
import json
import csv

def list_unused_disks_to_csv():
    # Get the list of all disks in the project
    try:
        result = subprocess.run(
            ["gcloud", "compute", "disks", "list", "--format=json"],
            capture_output=True,
            text=True,
            check=True
        )
        all_disks = json.loads(result.stdout)
    except subprocess.CalledProcessError as e:
        print(f"Error fetching disks: {e}")
        return

    # Get the list of all instances and their attached disks
    try:
        result = subprocess.run(
            ["gcloud", "compute", "instances", "list", "--format=json"],
            capture_output=True,
            text=True,
            check=True
        )
        instances = json.loads(result.stdout)
    except subprocess.CalledProcessError as e:
        print(f"Error fetching instances: {e}")
        return

    # Extract attached disk URLs
    attached_disks = set()
    for instance in instances:
        for disk in instance.get('disks', []):
            attached_disks.add(disk['source'])

    # Identify unused disks
    unused_disks = [disk for disk in all_disks if disk['selfLink'] not in attached_disks]

    # Write unused disks to a CSV file
    csv_file = "unused_disks.csv"
    with open(csv_file, mode='w', newline='') as file:
        writer = csv.writer(file)
        writer.writerow(["Disk Name", "Zone", "Disk Type"])  # Header row
        for disk in unused_disks:
            # Determine the disk type
            disk_type = "unknown"
            if "type" in disk:
                if "pd-ssd" in disk["type"]:
                    disk_type = "SSD"
                elif "pd-balanced" in disk["type"]:
                    disk_type = "Balanced"
                elif "pd-standard" in disk["type"]:
                    disk_type = "Standard"
            writer.writerow([disk['name'], disk['zone'], disk_type])
    
    print(f"Unused disks have been saved to {csv_file}")

if __name__ == "__main__":
    list_unused_disks_to_csv()
