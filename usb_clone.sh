#!/usr/bin/env python3
"""
===============================================================================
         ULTIMATE USB DRIVE CLONER / FLASHER / IMAGE CREATOR
===============================================================================
Title: Ultimate USB Drive Cloner, Flasher & Image Creation Utility

About:
    This utility supports four modes:

      1. Flash from a saved image:
         - Scans the current directory for files ending in ".img".
         - You select one from a 1-indexed list to flash onto a destination USB drive.
         - If the image is larger than the destination drive, the script will attempt
           to shrink it using PiShrink before flashing.

      2. Clone drive to drive:
         - You select a SOURCE and a DESTINATION USB drive.
         - If the source drive is raw (has no partitions), you’re offered the option
           to save an image first. The clone is performed either by cloning the partition
           table/partitions or as a raw clone (with image shrinking if needed).
         - Ext4 filesystems are automatically resized to fill the partition.
      
      3. Create an image from a USB drive:
         - You select a USB drive, and then provide a new name.
         - The script creates an image file (with ".img" appended) from the entire drive.
      
      4. Compress (shrink) a saved image:
         - Lists existing ".img" files.
         - You select one and then specify a new name.
         - The script runs PiShrink (with automatic “yes” responses) on the selected image
           and saves the shrunk version under the new name.

    After operations complete, the script calls 'sync' and, if applicable, attempts to eject
    the target drive. The program then exits cleanly.
===============================================================================
"""

import os
import sys
import subprocess
import json
import re
import tempfile
import glob

def list_saved_images():
    """Return a list of .img files in the current directory."""
    return glob.glob("*.img")

def list_usb_drives():
    """
    Lists available USB drives using lsblk's JSON output.
    Returns a list of dictionaries representing each USB drive.
    """
    try:
        result = subprocess.run(
            ["lsblk", "--json", "-o", "NAME,TYPE,TRAN,SIZE,MODEL"],
            capture_output=True, text=True, check=True
        )
        data = json.loads(result.stdout)
        usb_drives = [dev for dev in data.get("blockdevices", [])
                      if dev.get("type") == "disk" and dev.get("tran") == "usb"]
        if not usb_drives:
            print("No USB drives found.")
            sys.exit(1)
        print("Available USB drives:")
        for idx, drive in enumerate(usb_drives, start=1):
            name = drive.get("name", "Unknown")
            size = drive.get("size", "Unknown")
            model = drive.get("model", "Unknown")
            print(f"[{idx}] /dev/{name} - Size: {size}, Model: {model}")
        return usb_drives
    except subprocess.CalledProcessError as e:
        print(f"Error listing USB drives: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"Unexpected error: {e}")
        sys.exit(1)

def select_drive(usb_drives, prompt):
    """
    Prompts the user to select a USB drive from the list.
    The prompt (e.g. "SOURCE", "DESTINATION") is displayed.
    Returns the drive's device path (e.g., /dev/sdx).
    """
    while True:
        try:
            choice = int(input(f"Enter the number of the {prompt} drive you want to use: "))
            if 1 <= choice <= len(usb_drives):
                selected = usb_drives[choice - 1]  # adjust for 1-indexing
                drive_path = "/dev/" + selected.get("name")
                print(f"Selected {prompt} drive: {drive_path}")
                return drive_path
            else:
                print("Invalid number. Try again.")
        except ValueError:
            print("Please enter a valid number.")

def get_total_sectors(drive):
    """
    Returns the total number of sectors of the given drive.
    """
    try:
        result = subprocess.run(
            ["sudo", "blockdev", "--getsz", drive],
            capture_output=True, text=True, check=True
        )
        return int(result.stdout.strip())
    except subprocess.CalledProcessError as e:
        print(f"Error getting size for {drive}: {e}")
        sys.exit(1)

def get_drive_partitions(drive):
    """
    Returns the list of partitions (children) for the specified drive using lsblk.
    """
    try:
        result = subprocess.run(
            ["lsblk", "--json", "-o", "NAME,TYPE", drive],
            capture_output=True, text=True, check=True
        )
        data = json.loads(result.stdout)
        return data.get("blockdevices", [])[0].get("children", [])
    except Exception as e:
        return []

def clone_partition_table(source, destination):
    """
    Clones the partition table from the source drive to the destination drive.
    Adjusts partition sizes based on the destination drive.
    """
    print("\nCloning partition table from source to destination...")
    src_total = get_total_sectors(source)
    dest_total = get_total_sectors(destination)
    
    try:
        dump = subprocess.run(
            ["sudo", "sfdisk", "-d", source],
            capture_output=True, text=True, check=True
        ).stdout
    except subprocess.CalledProcessError as e:
        print(f"Error dumping partition table from {source}: {e.stderr.strip() if e.stderr else e}")
        sys.exit(1)

    dump = dump.replace(source, destination, 1)
    lines = dump.splitlines()
    new_lines = []
    part_lines = []
    for line in lines:
        if line.startswith(source):
            new_line = line.replace(source, destination, 1)
            part_lines.append(new_line)
            new_lines.append(new_line)
        else:
            new_lines.append(line)
    
    if part_lines:
        last_line = part_lines[-1]
        m = re.search(r"start=\s*(\d+),\s*size=\s*(\d+),", last_line)
        if m:
            start = int(m.group(1))
            old_size = int(m.group(2))
            new_size = dest_total - start
            if new_size < old_size:
                print("Warning: Destination drive is smaller than the source partition size.")
                confirm = input("Data loss might occur. Continue? (yes/no): ")
                if confirm.lower() != "yes":
                    sys.exit(0)
            new_line = re.sub(r"(size=\s*)\d+", f"\\1{new_size}", last_line)
            for i, line in enumerate(new_lines):
                if line == last_line:
                    new_lines[i] = new_line
                    break
    new_dump = "\n".join(new_lines) + "\n"
    
    with tempfile.NamedTemporaryFile("w", delete=False) as tmpf:
        tmpf.write(new_dump)
        tmp_filename = tmpf.name
    print(f"Modified partition table written to temporary file: {tmp_filename}")
    
    try:
        subprocess.run(["sudo", "sfdisk", destination], input=new_dump, text=True, check=True)
    except subprocess.CalledProcessError as e:
        print(f"Error writing partition table to {destination}: {e.stderr.strip() if e.stderr else e}")
        sys.exit(1)
    subprocess.run(["sudo", "partprobe", destination], check=True)
    print("Partition table cloned successfully.")

def clone_partitions(source, destination):
    """
    Clones each partition from the source drive to the destination drive using dd.
    Resizes ext4 filesystems to fill the new partition.
    """
    print("\nCloning partition data from source to destination...")
    try:
        result = subprocess.run(
            ["lsblk", "--json", "-o", "NAME,FSTYPE", destination],
            capture_output=True, text=True, check=True
        )
        data = json.loads(result.stdout)
    except subprocess.CalledProcessError as e:
        print(f"Error listing partitions on {destination}: {e}")
        sys.exit(1)
    children = data.get("blockdevices", [])[0].get("children", [])
    if not children:
        print("No partitions found on the destination drive after partitioning.")
        sys.exit(1)
    
    for child in children:
        part_name = child.get("name")
        fstype = child.get("fstype", "")
        dest_part = "/dev/" + part_name
        part_num = re.search(r"\d+$", part_name)
        if not part_num:
            continue
        src_part = source + part_num.group(0)
        print(f"\nCloning partition {src_part} -> {dest_part} ...")
        try:
            subprocess.run(
                ["sudo", "dd", f"if={src_part}", f"of={dest_part}", "bs=4M", "status=progress", "conv=fsync"],
                check=True
            )
        except subprocess.CalledProcessError as e:
            print(f"Error cloning partition {src_part}: {e}")
            sys.exit(1)
        if fstype == "ext4":
            print(f"Resizing ext4 filesystem on {dest_part} to fill partition...")
            try:
                subprocess.run(["sudo", "resize2fs", dest_part], check=True)
            except subprocess.CalledProcessError as e:
                print(f"Error resizing filesystem on {dest_part}: {e}")
                sys.exit(1)
    print("\nAll partitions cloned successfully.")

def raw_clone(source, destination):
    """
    Performs a raw clone of the entire drive using dd.
    If the destination drive is smaller than the source drive,
    an image is created and PiShrink is used to shrink it.
    """
    print("\nPerforming raw clone of the entire drive...")
    try:
        src_size = int(subprocess.run(
            ["sudo", "blockdev", "--getsize64", source],
            capture_output=True, text=True, check=True
        ).stdout.strip())
        dest_size = int(subprocess.run(
            ["sudo", "blockdev", "--getsize64", destination],
            capture_output=True, text=True, check=True
        ).stdout.strip())
    except subprocess.CalledProcessError as e:
        print(f"Error retrieving drive sizes: {e}")
        sys.exit(1)

    if dest_size < src_size:
        print(f"Destination drive is smaller than source drive.\nSource: {src_size} bytes, Destination: {dest_size} bytes.")
        print("Attempting to shrink the source image to fit the destination drive...")
        tmp_image = "/tmp/source_raw.img"
        shrunk_image = "/tmp/source_raw_shrunk.img"
        try:
            subprocess.run(
                ["sudo", "dd", f"if={source}", f"of={tmp_image}", "bs=4M", "status=progress", "conv=fsync"],
                check=True
            )
        except subprocess.CalledProcessError as e:
            print(f"Error creating source image: {e}")
            sys.exit(1)
        try:
            # Pipe "yes" to pishrink to automatically answer prompts.
            cmd = f'yes | sudo pishrink.sh "{tmp_image}" "{shrunk_image}"'
            subprocess.run(cmd, shell=True, check=True)
            image_to_use = shrunk_image
        except subprocess.CalledProcessError as e:
            print(f"Error during image shrinking: {e}")
            orig_size = os.path.getsize(tmp_image)
            print(f"The original image is saved at {tmp_image} (size: {orig_size} bytes).")
            use_orig = input("PiShrink failed. Would you like to use the original image as-is? (yes/no): ")
            if use_orig.lower() != "yes":
                sys.exit(1)
            image_to_use = tmp_image

        image_size = os.path.getsize(image_to_use)
        if image_size > dest_size:
            print(f"Warning: The image size ({image_size} bytes) is larger than the destination drive ({dest_size} bytes).")
            confirm = input("Proceed anyway? (yes/no): ")
            if confirm.lower() != "yes":
                sys.exit(1)
        print(f"Writing image {image_to_use} to destination...")
        try:
            subprocess.run(
                ["sudo", "dd", f"if={image_to_use}", f"of={destination}", "bs=4M", "status=progress", "conv=fsync"],
                check=True
            )
        except subprocess.CalledProcessError as e:
            print(f"Error writing image to destination: {e}")
            sys.exit(1)
        if image_to_use == shrunk_image:
            os.remove(tmp_image)
            os.remove(shrunk_image)
        print("Raw cloning complete with image shrinking.")
    else:
        try:
            subprocess.run(
                ["sudo", "dd", f"if={source}", f"of={destination}", "bs=4M", "status=progress", "conv=fsync"],
                check=True
            )
            print("Raw cloning complete.")
        except subprocess.CalledProcessError as e:
            print(f"Error during raw cloning: {e}")
            sys.exit(1)

def flash_image_to_drive(image_file, destination):
    """
    Flashes a saved image file to the destination drive.
    Shrinks the image using PiShrink if needed.
    """
    print(f"\nFlashing image {image_file} to destination {destination}...")
    try:
        dest_size = int(subprocess.run(
            ["sudo", "blockdev", "--getsize64", destination],
            capture_output=True, text=True, check=True
        ).stdout.strip())
    except subprocess.CalledProcessError as e:
        print(f"Error retrieving destination size: {e}")
        sys.exit(1)
    image_size = os.path.getsize(image_file)
    if image_size > dest_size:
        print(f"Image size ({image_size} bytes) is larger than destination drive ({dest_size} bytes).")
        print("Attempting to shrink the image using PiShrink...")
        shrunk_image = "/tmp/flash_shrunk.img"
        try:
            cmd = f'yes | sudo pishrink.sh "{image_file}" "{shrunk_image}"'
            subprocess.run(cmd, shell=True, check=True)
            image_to_use = shrunk_image
        except subprocess.CalledProcessError as e:
            print(f"Error during image shrinking: {e}")
            print(f"The original image is saved at {image_file}.")
            use_orig = input("Would you like to use the original image anyway? (yes/no): ")
            if use_orig.lower() != "yes":
                sys.exit(1)
            image_to_use = image_file
        if os.path.getsize(image_to_use) > dest_size:
            print("Error: Even after shrinking, the image does not fit the destination drive.")
            sys.exit(1)
        print(f"Writing image {image_to_use} to destination...")
        try:
            subprocess.run(["sudo", "dd", f"if={image_to_use}", f"of={destination}", "bs=4M", "status=progress", "conv=fsync"], check=True)
        except subprocess.CalledProcessError as e:
            print(f"Error writing image to destination: {e}")
            sys.exit(1)
        if image_to_use == shrunk_image:
            os.remove(shrunk_image)
    else:
        try:
            subprocess.run(["sudo", "dd", f"if={image_file}", f"of={destination}", "bs=4M", "status=progress", "conv=fsync"], check=True)
        except subprocess.CalledProcessError as e:
            print(f"Error writing image to destination: {e}")
            sys.exit(1)
    print("Flashing complete.")

def create_image_from_drive(source, image_file):
    """
    Creates an image of the given source drive and saves it to image_file.
    """
    print(f"\nCreating image from {source} and saving as {image_file} ...")
    try:
        subprocess.run(["sudo", "dd", f"if={source}", f"of={image_file}", "bs=4M", "status=progress", "conv=fsync"], check=True)
    except subprocess.CalledProcessError as e:
        print(f"Error creating image from drive: {e}")
        sys.exit(1)
    print("Image creation complete.")

def finalize(eject_drive=None):
    """
    Finalizes the operation by flushing disk buffers.
    If an eject_drive is provided, attempts to eject it.
    Then exits the program.
    """
    print("\nFinalizing... flushing disk buffers (sync). Please wait.")
    subprocess.run(["sync"])
    print("Finalization complete. It is now safe to remove the USB drive.")
    if eject_drive:
        try:
            subprocess.run(["udisksctl", "power-off", "-b", eject_drive], check=True)
            print(f"Drive {eject_drive} has been ejected.")
        except subprocess.CalledProcessError:
            print("Failed to eject the drive automatically.")
    sys.exit(0)

def main():
    os.system("clear")  # Clear the terminal at startup
    print("\n*** USB DRIVE CLONER / FLASHER / IMAGE CREATOR ***\n")
    
    # List saved images in the current directory.
    saved_images = list_saved_images()
    if saved_images:
        print("Saved images found in the current directory:")
        for i, img in enumerate(saved_images, start=1):
            size = os.path.getsize(img)
            print(f"[{i}] {img} - {size} bytes")
    else:
        print("No saved images found in the current directory.")
    
    print("\nOptions:")
    print("1: Flash from a saved image")
    print("2: Clone drive to drive")
    print("3: Create an image from a USB drive")
    print("4: Compress (shrink) a saved image")
    option = input("Enter option number: ").strip()
    
    if option == "1":
        if not saved_images:
            print("No saved images available.")
            sys.exit(1)
        try:
            choice = int(input("Enter the number of the image to use: "))
            if choice < 1 or choice > len(saved_images):
                raise ValueError("Invalid selection")
            image_file = saved_images[choice - 1]
        except (ValueError, IndexError):
            print("Invalid selection.")
            sys.exit(1)
        dest_drive = select_drive(list_usb_drives(), "DESTINATION")
        flash_image_to_drive(image_file, dest_drive)
        finalize(eject_drive=dest_drive)
        
    elif option == "2":
        usb_drives = list_usb_drives()
        source_drive = select_drive(usb_drives, "SOURCE")
        destination_drive = select_drive(usb_drives, "DESTINATION")
        if source_drive == destination_drive:
            print("SOURCE and DESTINATION drives cannot be the same!")
            sys.exit(1)
        print(f"\nYou have selected:\n  SOURCE:      {source_drive}\n  DESTINATION: {destination_drive}")
        confirm = input("Proceed with cloning? This will ERASE ALL data on the destination drive. (yes/no): ")
        if confirm.lower() != "yes":
            print("Aborting operation.")
            sys.exit(0)
        partitions = get_drive_partitions(source_drive)
        if not partitions:
            print(f"\nSource drive {source_drive} appears to be raw (no partitions found).")
            confirm = input("Would you like to perform a raw clone of the entire drive? (yes/no): ")
            if confirm.lower() != "yes":
                sys.exit(0)
            save_img = input("Would you like to save an image of the source drive? (yes/no): ")
            if save_img.lower() == "yes":
                name = input("Enter a name for the saved image (without extension): ").strip()
                image_file = name + ".img"
                try:
                    subprocess.run(["sudo", "dd", f"if={source_drive}", f"of={image_file}", "bs=4M", "status=progress", "conv=fsync"], check=True)
                except subprocess.CalledProcessError as e:
                    print(f"Error creating image: {e}")
                    sys.exit(1)
                print(f"Image saved as {image_file}")
            raw_clone(source_drive, destination_drive)
        else:
            clone_partition_table(source_drive, destination_drive)
            clone_partitions(source_drive, destination_drive)
            save_img = input("Would you like to save an image of the source drive? (yes/no): ")
            if save_img.lower() == "yes":
                name = input("Enter a name for the saved image (without extension): ").strip()
                image_file = name + ".img"
                try:
                    subprocess.run(["sudo", "dd", f"if={source_drive}", f"of={image_file}", "bs=4M", "status=progress", "conv=fsync"], check=True)
                except subprocess.CalledProcessError as e:
                    print(f"Error creating image: {e}")
                    sys.exit(1)
                print(f"Image saved as {image_file}")
        finalize(eject_drive=destination_drive)
        
    elif option == "3":
        usb_drives = list_usb_drives()
        source_drive = select_drive(usb_drives, "SOURCE")
        name = input("Enter a name for the new image (without extension): ").strip()
        image_file = name + ".img"
        create_image_from_drive(source_drive, image_file)
        finalize()  # Not ejecting drive because we're only creating an image.
        
    elif option == "4":
        if not saved_images:
            print("No saved images available.")
            sys.exit(1)
        print("Select an image to compress:")
        for i, img in enumerate(saved_images, start=1):
            size = os.path.getsize(img)
            print(f"[{i}] {img} - {size} bytes")
        try:
            choice = int(input("Enter the number of the image to compress: "))
            if choice < 1 or choice > len(saved_images):
                raise ValueError("Invalid selection")
            orig_image = saved_images[choice - 1]
        except (ValueError, IndexError):
            print("Invalid selection.")
            sys.exit(1)
        new_name = input("Enter a new name for the compressed image (without extension): ").strip()
        new_image = new_name + ".img"
        try:
            # Pipe "yes" to automatically answer all prompts
            cmd = f'yes | sudo pishrink.sh "{orig_image}" "{new_image}"'
            subprocess.run(cmd, shell=True, check=True)
            print(f"Image compressed and saved as {new_image}")
        except subprocess.CalledProcessError as e:
            print(f"Error compressing the image: {e}")
            sys.exit(1)
        finalize()
        
    else:
        print("Invalid option selected.")
        sys.exit(1)

if __name__ == "__main__":
    if os.geteuid() != 0:
        print("This script must be run as root. Please run with sudo.")
        sys.exit(1)
    main()
