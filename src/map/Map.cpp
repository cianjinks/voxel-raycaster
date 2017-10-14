#include "map/Map.h"
#include "Logger.h"


Map::Map(uint32_t dimensions, Old_Map* array_map) {


	if ((int)pow(2, (int)log2(dimensions)) != dimensions)
		Logger::log("Map dimensions not an even exponent of 2", Logger::LogLevel::ERROR, __LINE__, __FILE__);

	voxel_data = new char[dimensions * dimensions * dimensions];

	// randomly set the voxel data for testing
	for (uint64_t i = 0; i < dimensions * dimensions * dimensions; i++) {
		//if (rand() % 10000 < 3)
		//	voxel_data[i] = 1;
		//else
			voxel_data[i] = 0;
	}

	char* char_array = array_map->get_voxel_data();
	sf::Vector3i arr_dimensions = array_map->getDimensions();

	for (int x = 0; x < dimensions; x++) {
		for (int y = 0; y < dimensions; y++) {
			for (int z = 0; z < dimensions; z++) {
				
				char v = char_array[x + arr_dimensions.x * (y + arr_dimensions.z * z)];
				if (v)
					voxel_data[x + dimensions * (y + dimensions * z)] = 1;
			}
		}
	}

	sf::Vector3i dim3(dimensions, dimensions, dimensions);

	Logger::log("Generating Octree", Logger::LogLevel::INFO);
	octree.Generate(voxel_data, dim3);

	Logger::log("Validating Octree", Logger::LogLevel::INFO);
	if (!octree.Validate(voxel_data, dim3)) {
		Logger::log("Octree validation failed", Logger::LogLevel::ERROR, __LINE__, __FILE__);
	}

	// TODO: Create test with mock octree data and defined test framework
	Logger::log("Testing Array vs Octree ray traversal", Logger::LogLevel::INFO);
	if (!test_oct_arr_traversal(dim3)) {
		Logger::log("Array and Octree traversals DID NOT MATCH!!!", Logger::LogLevel::ERROR, __LINE__, __FILE__);
	}
	
}

bool Map::test_oct_arr_traversal(sf::Vector3i dimensions) {

	//sf::Vector2f cam_dir(0.95, 0.81);
	//sf::Vector3f cam_pos(10.5, 10.5, 10.5);
	//std::vector<std::tuple<sf::Vector3i, char>> list1 = CastRayCharArray(voxel_data, &dimensions, &cam_dir, &cam_pos);
	//std::vector<std::tuple<sf::Vector3i, char>> list2 = CastRayOctree(&octree, &dimensions, &cam_dir, &cam_pos);

	//if (list1 != list2) {
	//	return false;
	//} else {
	//	return true;
	//}


	return false;
}

void Map::setVoxel(sf::Vector3i pos, int val) {
    voxel_data[pos.x + octree.getDimensions() * (pos.y + octree.getDimensions() * pos.z)] = val;
}

char Map::getVoxel(sf::Vector3i pos){
	return octree.GetVoxel(pos).found;
}


std::vector<std::tuple<sf::Vector3i, char>>  Map::CastRayCharArray(
	char* map,
	sf::Vector3i* map_dim,
	sf::Vector2f* cam_dir,
	sf::Vector3f* cam_pos
) {
	// Setup the voxel coords from the camera origin
	sf::Vector3i voxel(*cam_pos);

	std::vector<std::tuple<sf::Vector3i, char>> travel_path;

	sf::Vector3f ray_dir(1, 0, 0);

	// Pitch
	ray_dir = sf::Vector3f(
		ray_dir.z * sin((*cam_dir).x) + ray_dir.x * cos((*cam_dir).x),
		ray_dir.y,
		ray_dir.z * cos((*cam_dir).x) - ray_dir.x * sin((*cam_dir).x)
		);

	// Yaw
	ray_dir = sf::Vector3f(
		ray_dir.x * cos((*cam_dir).y) - ray_dir.y * sin((*cam_dir).y),
		ray_dir.x * sin((*cam_dir).y) + ray_dir.y * cos((*cam_dir).y),
		ray_dir.z
	);

	// correct for the base ray pointing to (1, 0, 0) as (0, 0). Should equal (1.57, 0)
	ray_dir = sf::Vector3f(
		static_cast<float>(ray_dir.z * sin(-1.57) + ray_dir.x * cos(-1.57)),
		static_cast<float>(ray_dir.y),
		static_cast<float>(ray_dir.z * cos(-1.57) - ray_dir.x * sin(-1.57))
	);


	// Setup the voxel step based on what direction the ray is pointing
	sf::Vector3i voxel_step(1, 1, 1);

	voxel_step.x *= (ray_dir.x > 0) - (ray_dir.x < 0);
	voxel_step.y *= (ray_dir.y > 0) - (ray_dir.y < 0);
	voxel_step.z *= (ray_dir.z > 0) - (ray_dir.z < 0);


	// Delta T is the units a ray must travel along an axis in order to
	// traverse an integer split
	sf::Vector3f delta_t(
		fabs(1.0f / ray_dir.x),
		fabs(1.0f / ray_dir.y),
		fabs(1.0f / ray_dir.z)
	);

	// offset is how far we are into a voxel, enables sub voxel movement
	// Intersection T is the collection of the next intersection points
	// for all 3 axis XYZ.
	sf::Vector3f intersection_t(
		delta_t.x * (cam_pos->x - floor(cam_pos->x)) * voxel_step.x,
		delta_t.y * (cam_pos->y - floor(cam_pos->y)) * voxel_step.y,
		delta_t.z * (cam_pos->z - floor(cam_pos->z)) * voxel_step.z
	);

	// for negative values, wrap around the delta_t
	intersection_t.x -= delta_t.x * (std::min(intersection_t.x, 0.0f));
	intersection_t.y -= delta_t.y * (std::min(intersection_t.y, 0.0f));
	intersection_t.z -= delta_t.z * (std::min(intersection_t.z, 0.0f));


	int dist = 0;
	sf::Vector3i face_mask(0, 0, 0);
	int voxel_data = 0;

	// Andrew Woo's raycasting algo
	do {

		face_mask.x = intersection_t.x <= std::min(intersection_t.y, intersection_t.z);
		face_mask.y = intersection_t.y <= std::min(intersection_t.z, intersection_t.x);
		face_mask.z = intersection_t.z <= std::min(intersection_t.x, intersection_t.y);

		intersection_t.x += delta_t.x * fabs(face_mask.x);
		intersection_t.y += delta_t.y * fabs(face_mask.y);
		intersection_t.z += delta_t.z * fabs(face_mask.z);

		voxel.x += voxel_step.x * face_mask.x;
		voxel.y += voxel_step.y * face_mask.y;
		voxel.z += voxel_step.z * face_mask.z;

		if (voxel.x >= map_dim->x || voxel.y >= map_dim->y || voxel.z >= map_dim->z) {
			return travel_path;
		}
		if (voxel.x < 0 || voxel.y < 0 || voxel.z < 0) {
			return travel_path;
		}

		// If we hit a voxel
		voxel_data = map[voxel.x + (*map_dim).x * (voxel.y + (*map_dim).z * (voxel.z))];

		travel_path.push_back(std::make_tuple(voxel, voxel_data));

		if (voxel_data != 0)
			return travel_path;
		

	} while (++dist < 700.0f);

	return travel_path;
}

class Octree;

std::vector<std::tuple<sf::Vector3i, char>> Map::CastRayOctree(
	Octree *octree,
	sf::Vector3i* map_dim,
	sf::Vector2f* cam_dir,
	sf::Vector3f* cam_pos
) {

	// Setup the voxel coords from the camera origin
	sf::Vector3i voxel(0,0,0);

	// THIS DOES NOT HAVE TO RETURN TRUE ON FOUND
	// This function when passed an "air" voxel will return as far down
	// the IDX stack as it could go. We use this oct-level to determine
	// our first position and jump. Updating it as we go
	OctState traversal_state = octree->GetVoxel(voxel);

	std::vector<std::tuple<sf::Vector3i, char>> travel_path;

	sf::Vector3f ray_dir(1, 0, 0);

	// Pitch
	ray_dir = sf::Vector3f(
		ray_dir.z * sin((*cam_dir).x) + ray_dir.x * cos((*cam_dir).x),
		ray_dir.y,
		ray_dir.z * cos((*cam_dir).x) - ray_dir.x * sin((*cam_dir).x)
	);

	// Yaw
	ray_dir = sf::Vector3f(
		ray_dir.x * cos((*cam_dir).y) - ray_dir.y * sin((*cam_dir).y),
		ray_dir.x * sin((*cam_dir).y) + ray_dir.y * cos((*cam_dir).y),
		ray_dir.z
	);

	// correct for the base ray pointing to (1, 0, 0) as (0, 0). Should equal (1.57, 0)
	ray_dir = sf::Vector3f(
		static_cast<float>(ray_dir.z * sin(-1.57) + ray_dir.x * cos(-1.57)),
		static_cast<float>(ray_dir.y),
		static_cast<float>(ray_dir.z * cos(-1.57) - ray_dir.x * sin(-1.57))
	);


	// Setup the voxel step based on what direction the ray is pointing
	sf::Vector3i voxel_step(1, 1, 1);

	voxel_step.x *= (ray_dir.x > 0) - (ray_dir.x < 0);
	voxel_step.y *= (ray_dir.y > 0) - (ray_dir.y < 0);
	voxel_step.z *= (ray_dir.z > 0) - (ray_dir.z < 0);
	
	// set the jump multiplier based on the traversal state vs the log base 2 of the maps dimensions
	int jump_power = log2(map_dim->x) - traversal_state.scale;


	// Delta T is the units a ray must travel along an axis in order to
	// traverse an integer split
	sf::Vector3f delta_t(
		fabs(1.0f / ray_dir.x),
		fabs(1.0f / ray_dir.y),
		fabs(1.0f / ray_dir.z)
	);

	delta_t *= static_cast<float>(jump_power);

	// TODO: start here
	// Whats the issue?
	//		Using traversal_scale 
	// set intersection t to the current hierarchy level each time we change levels
	// and use that to step

	
	// Intersection T is the collection of the next intersection points
	// for all 3 axis XYZ. We take the full positive cardinality when
	// subtracting the floor, so we must transfer the sign over from
	// the voxel step
	sf::Vector3f intersection_t(
		delta_t.x * (cam_pos->y - floor(cam_pos->x)) * voxel_step.x,
		delta_t.y * (cam_pos->x - floor(cam_pos->y)) * voxel_step.y,
		delta_t.z * (cam_pos->z - floor(cam_pos->z)) * voxel_step.z
	);

	// When we transfer the sign over, we get the correct direction of 
	// the offset, but we merely transposed over the value instead of mirroring
	// it over the axis like we want. So here, isless returns a boolean if intersection_t
	// is less than 0 which dictates whether or not we subtract the delta which in effect
	// mirrors the offset
	intersection_t.x -= delta_t.x * (std::isless(intersection_t.x, 0.0f));
	intersection_t.y -= delta_t.y * (std::isless(intersection_t.y, 0.0f));
	intersection_t.z -= delta_t.z * (std::isless(intersection_t.z, 0.0f));

	int dist = 0;
	sf::Vector3i face_mask(0, 0, 0);
	int voxel_data = 0;

	// Andrew Woo's raycasting algo
	do {

		// check which direction we step in
		face_mask.x = intersection_t.x <= std::min(intersection_t.y, intersection_t.z);
		face_mask.y = intersection_t.y <= std::min(intersection_t.z, intersection_t.x);
		face_mask.z = intersection_t.z <= std::min(intersection_t.x, intersection_t.y);

		// Increment the selected directions intersection, abs the face_mask to stay within the algo constraints
		intersection_t.x += delta_t.x * fabs(face_mask.x);
		intersection_t.y += delta_t.y * fabs(face_mask.y);
		intersection_t.z += delta_t.z * fabs(face_mask.z);

		// step the voxel direction
		voxel.x += voxel_step.x * face_mask.x * jump_power;
		voxel.y += voxel_step.y * face_mask.y * jump_power;
		voxel.z += voxel_step.z * face_mask.z * jump_power;

		uint8_t prev_val = traversal_state.idx_stack[traversal_state.scale];
		uint8_t this_face_mask = 0;

		// Check the voxel face that we traversed
		// and increment the idx in the idx stack
		if (face_mask.x) {
			this_face_mask = Octree::idx_set_x_mask;
		}
		else if (face_mask.y) {
			this_face_mask = Octree::idx_set_y_mask;
		}
		else if (face_mask.z) {
			this_face_mask = Octree::idx_set_z_mask;
		}

		traversal_state.idx_stack[traversal_state.scale] ^= this_face_mask;
		int mask_index = traversal_state.idx_stack[traversal_state.scale];

		// Check to see if the idx increased or decreased	
		// If it decreased
		//		Pop up the stack until the oct that the idx flip is valid and we landed on a valid oct
		while (traversal_state.idx_stack[traversal_state.scale] < prev_val ||
			!((traversal_state.parent_stack[traversal_state.parent_stack_position] >> 16) & Octree::mask_8[mask_index])
			) {
			
			jump_power *= 2;
			
			// Keep track of the 0th edge of out current oct
			traversal_state.oct_pos.x = floor(voxel.x / 2) * jump_power;
			traversal_state.oct_pos.y = floor(voxel.x / 2) * jump_power;
			traversal_state.oct_pos.z = floor(voxel.x / 2) * jump_power;

			// Clear and pop the idx stack
			traversal_state.idx_stack[traversal_state.scale] = 0;
			traversal_state.scale--;
			
			// Update the prev_val for our new idx
			prev_val = traversal_state.idx_stack[traversal_state.scale];
			
			// Clear and pop the parent stack, maybe off by one error?
			traversal_state.parent_stack[traversal_state.parent_stack_position] = 0;
			traversal_state.parent_stack_position--;

			// Set the current CD to the one on top of the stack
			traversal_state.current_descriptor =
				traversal_state.parent_stack[traversal_state.parent_stack_position];
			
			// Apply the face mask to the new idx for the while check
			traversal_state.idx_stack[traversal_state.scale] ^= this_face_mask;
			mask_index = traversal_state.idx_stack[traversal_state.scale];
		}
		

		// Check to see if we are on a valid oct
		//if ((traversal_state.parent_stack[traversal_state.parent_stack_position] >> 16) & Octree::mask_8[mask_index]) {

		//	// Check to see if it is a leaf
		//	if ((traversal_state.parent_stack[traversal_state.parent_stack_position] >> 24) & Octree::mask_8[mask_index]) {

		//		// If it is, then we cannot traverse further as CP's won't have been generated
		//		state.found = 1;
		//		return state;
		//	}
		//}
		//	Check to see if we are on top of a valid branch
		//	Traverse down to the lowest valid oct that the ray is within

		// When we pass a split, then that means that we traversed SCALE number of voxels in that direction


		// while the bit is valid and we are not bottomed out
		//		get the cp of the valid branch
		//		
		//
		//
		//



	
	
	
		if (voxel.x >= map_dim->x || voxel.y >= map_dim->y || voxel.z >= map_dim->z) {
			return travel_path;
		}
		if (voxel.x < 0 || voxel.y < 0 || voxel.z < 0) {
			return travel_path;
		}

		// If we hit a voxel
		//voxel_data = map[voxel.x + (*map_dim).x * (voxel.y + (*map_dim).z * (voxel.z))];
//		voxel_data = getVoxel(voxel);
		travel_path.push_back(std::make_tuple(voxel, voxel_data));

		if (voxel_data != 0)
			return travel_path;


	} while (++dist < 700.0f);

	return travel_path;
}