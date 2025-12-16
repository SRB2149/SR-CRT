# .mi 325x256 Image Viewer
# Just a simple tkinter image viewer to check your .mi files are saved as intended
#
# Copyright (C) 2025 Stanley Booth - All Rights Reserved
# You may use, distribute and modify this code under the
# terms of the MIT license

import tkinter as tk

xMax = 296
yMax = 256
TOTAL_PIXELS = xMax * yMax
TOTAL_WORDS  = TOTAL_PIXELS // 8

# Initialize image buffer
image = []
for y in range(yMax):
    image.append([0] * xMax)

# Open .mi file
gettingFile = True
while gettingFile:
    name = input("Enter the .mi file: ")
    try:
        if ".mi" in name:
            file = open(name, "r")
            gettingFile = False
        else:
            print("ERROR: Filename invalid (must be a .mi file)\n")
    except:
        print("ERROR: File cannot be found, check the name.\n")

pixel_index = 0
words_read = 0

for line in file:
    line = line.strip()

    # Skip headers
    if line.startswith("#") or line == "":
        continue

    if words_read >= TOTAL_WORDS:
        break

    if len(line) != 8:
        raise ValueError("Invalid word length at word " + str(words_read))

    for _ in range(8):
        if pixel_index >= TOTAL_PIXELS:
            break

        y = pixel_index // xMax
        x = pixel_index % xMax

        bit_index = pixel_index & 0b111      # 0..7
        image[y][x] = 1 if line[7 - bit_index] == '1' else 0

        pixel_index += 1

    words_read += 1

file.close()

print("Words read:", words_read)
print("Pixels reconstructed:", pixel_index)

PIXEL_SIZE = 2  # scale factor for visibility

root = tk.Tk()
root.title("MI Image Viewer")

canvas = tk.Canvas(
    root,
    width=xMax * PIXEL_SIZE,
    height=yMax * PIXEL_SIZE,
    bg="black"
)
canvas.pack()

# Draw pixels
for y in range(yMax):
    for x in range(xMax):
        if image[y][x]:
            x0 = x * PIXEL_SIZE
            y0 = y * PIXEL_SIZE
            x1 = x0 + PIXEL_SIZE
            y1 = y0 + PIXEL_SIZE
            canvas.create_rectangle(
                x0, y0, x1, y1,
                fill="white",
                outline=""
            )

root.mainloop()
