all: run

# 1. Assemble the kernel into an ELF32 object file
kernel.o: kernel.asm
	nasm -f elf32 kernel.asm -o kernel.o

# 2. Link the object file into the final bootable binary
nova.bin: kernel.o linker.ld
	ld -m elf_i386 -T linker.ld kernel.o -o nova.bin

# 3. Create a REAL FAT32 hard drive and inject files and folders!
hdd.img:
	@echo "Creating a 64MB virtual hard drive..."
	# We use 64MB to guarantee mkfs.fat formats it as pure FAT32
	dd if=/dev/zero of=hdd.img bs=1M count=64 2>/dev/null
	
	@echo "Formatting the drive as FAT32..."
	mkfs.fat -F 32 -n "NOVA_DISK" hdd.img
	
	@echo "Generating text files..."
	echo "Congratulations! You are reading this from the root directory!" > root.txt
	echo "Level 1: The Cave. Enemies: 3. Health: 100." > game.txt
	echo "TOP SECRET: The kernel is actually 3 raccoons in a trenchcoat." > secret.txt
	
	@echo "Building directory structure and injecting files..."
	# mmd creates directories inside the FAT32 image
	mmd -i hdd.img ::SYSTEM
	mmd -i hdd.img ::DOCS
	
	# mcopy injects files. Notice the ::DOCS/ path!
	mcopy -i hdd.img root.txt ::root.txt
	mcopy -i hdd.img game.txt ::game.txt
	mcopy -i hdd.img secret.txt ::DOCS/secret.txt

# 4. Run the OS in QEMU!
run: nova.bin hdd.img
	qemu-system-i386 -kernel nova.bin -m 32M -drive file=hdd.img,format=raw,index=0,media=disk,cache=writethrough
# Clean up build files AND our temporary text files
clean:
	rm -f *.o *.bin hdd.img root.txt game.txt secret.txt