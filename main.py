# Mapping dari Usable Hosts ke CIDR
usable_hosts_to_cidr = {
    2: "/30", 
    6: "/29", 
    14: "/28", 
    30: "/27", 
    62: "/26",
    126: "/25", 
    254: "/24", 
    510: "/23", 
    1022: "/22", 
    2046: "/21", 
    4094: "/20", 
    8190: "/19", 
    16382: "/18",
    32766: "/17", 
    65534: "/16",
    131070: "/15", 
    262142: "/14", 
    524286: "/13", 
    1048574: "/12", 
    2097150: "/11",
    4194302: "/10", 
    8388606: "/9", 
    16777214: "/8"
}

# Fungsi untuk mencari CIDR dari jumlah usable hosts
def get_cidr(usable_hosts):
    # Cari nilai yang cocok
    if usable_hosts in usable_hosts_to_cidr:
        return usable_hosts_to_cidr[usable_hosts]
    # Jika tidak cocok, cari nilai terdekat di atas
    sorted_hosts = sorted(usable_hosts_to_cidr.keys())
    for hosts in sorted_hosts:
        if usable_hosts < hosts:
            return usable_hosts_to_cidr[hosts]
    return "Unknown"  # Jika semua gagal (tidak mungkin terjadi karena batas map)

# Membaca file data.txt
with open("data.txt", "r") as file:
    lines = file.readlines()

# Proses setiap baris
result = []
for line in lines:
    columns = line.strip().split("\t")  # Pisahkan kolom berdasarkan tab
    if len(columns) >= 3:  # Pastikan ada setidaknya 3 kolom
        ip_range = columns[0]
        usable_hosts = int(columns[2].replace(",", "")) - 2  # Hapus koma, ubah ke integer, lalu kurangi 2
        cidr = get_cidr(usable_hosts)  # Konversi jumlah usable hosts ke CIDR
        result.append([ip_range, cidr])  # Simpan IP range dan CIDR

# Menampilkan hasil
with open("result.txt", "w") as output_file:
    for item in result:
        output_file.write("".join(item) + "\n")