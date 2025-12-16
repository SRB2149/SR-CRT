# Converts the C file export option (of a black (00000000) and white (ffffffff) image) from https://www.piskelapp.com/ 
# into a .mi file needed by the Gowin bsram init menu.
# Frame Buffer settings:
# File Name:        crt_frame_buffer_dpbsram
# Name:             CRT_FRAME_BUFFER_DPBSRAM
# Language:         Verilog
# Address_depth:    9472
# Data width:       8
# Read mode:        Bypass
# Write mode:       Normal
# Then select your generated mi file
#
# Effective pixel layout:
# Pixels read from top left to bottom right and stored one after the other (for 100% packing efficiency)
# To read/write specific pixel:     pixel_index = y * xMax + x
# Word address:                     word_addr   = pixel_index >> 3     (Divide by 8)
# Bit Index:                        bit_index   = pixel_index & 0b111 (select last 3 bits)
#
# Copyright (C) 2025 Stanley Booth - All Rights Reserved
# You may use, distribute and modify this code under the
# terms of the MIT license

# !! FOR 296x256 'IMAGES' ONLY !!

xMax = 296
yMax = 256
image = []

for i in range(xMax):
    image.append([])

gettingFile = True
while (gettingFile):
    name = input(f"Enter the piskel c file ({xMax}x{yMax} pixels): ")
    
    try:
        if (".c" in name):
            file = open(name, "r")
            gettingFile = False
        else:
            print("ERROR: Filename invalid (must be a .c file)\n")
    except:
        print("ERROR: File cannot be found, check the name.\n")

prevChar = ''
sampleNext = False
pixelsFound = 0;
xCoord = 0
yCoord = 0

while 1:
    c = file.read(1)
    
    if (not c):
        break
    
    if (sampleNext):
        xCoord += 1
        
        if (c == '0'):
            image[yCoord].append(0)
        elif (c != '0'):
            image[yCoord].append(1)
            
        if (xCoord == xMax):
            xCoord = 0
            yCoord += 1
        
        pixelsFound += 1;        
        sampleNext = False
        
    elif (prevChar == '0' and c == 'x'):
        sampleNext = True
    
    prevChar = c

file.close()
  
print("\nPixels found: " + str(pixelsFound))
   
name_init = name.replace(".c", "") + ".mi"
file = open(name_init, "w")
file.write("#File_format=Bin\n")
file.write("#Address_depth=9472\n")
file.write("#Data_width=8\n")

TOTAL_PIXELS = xMax * yMax  # 296 * 256 = 75776
TOTAL_WORDS  = TOTAL_PIXELS // 8  # 9472

pixel_index = 0

for word in range(TOTAL_WORDS):
    bits = ["0"] * 8

    for bit in range(8):
        y = pixel_index // xMax
        x = pixel_index % xMax

        bit_index = pixel_index & 0b1111   # 0..7
        bits[7 - bit_index] = str(image[y][x])

        pixel_index += 1

    pixWord = "".join(bits)
    file.write(pixWord + "\n")

print("Finished. Data saved in " + name_init)
    