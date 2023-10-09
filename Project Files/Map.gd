extends Node2D
var noise_map 

var voxels = {}
#@export var alt_freq : float = 0.005
@export var octaves : int = 4
@export var lacunarity : int = 2
@export var gain : float = 0.5
@export var amplitude : float = 1.0
@export var map_width : int = 10
@export var map_layers : int = 7
@export var number_blocks : int = 5

func create_array(m: int, n: int) -> Array:
	var a := []
	a.resize(m)
	for i in range(m):
		a[i] = []
		a[i].resize(n)
	return a

func new_map(random_seed, oct, lac, g):
	noise_map = FastNoiseLite.new()
	noise_map.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise_map.seed = random_seed
	noise_map.fractal_octaves = oct
	noise_map.fractal_lacunarity = lac
	noise_map.fractal_gain = g
	for z in map_layers:
		voxels[z] = create_array(map_width, map_width)
		for _y in map_width:
			var y = _y - (map_width / 2)
			for _x in map_width:
				var x = _x - (map_width / 2)
				if (z > 0):
					if (voxels[z-1][_y][_x] == 0):
						voxels[z][_y][_x] = 0
						continue # air below = air at (x, y, z+1)
					# This is the terrain generation step. The noise value is used here
					voxels[z][_y][_x] = int(abs(noise_map.get_noise_2d(x, y) * 1000)) % number_blocks
					print(x, "(", _x, ") ", y, "(", _y, ") ", z, " = ", voxels[z][_y][_x])
					

# Called when the node enters the scene tree for the first time.
func _ready():
	new_map(1234, octaves, lacunarity, gain)

	
	
	

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	pass
