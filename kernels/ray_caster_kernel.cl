/*

Notes:

Keep this is mind when masking the voxel steps, pretty unintuitive behaviour

	For scalar types, the equality operators return 0 if false and return 1 if true
	For vector types, the equality operators return 0 if false and return -1 if true (i.e. all bits set)
	The equality equal (==) returns 0 if one or both arguments are not a number (NaN).
	The equality not equal (!=) returns 1 (for scalar source operands) or -1 (for vector source
	operands) if one or both arguments are not a number (NaN).

	if statements will take 0 as false and any other integer as true


*/

// =========================================================================
// ======================== INITIALIZER CONSTANTS ==========================

__constant float4 zeroed_float4 = {0.0f, 0.0f, 0.0f, 0.0f};
__constant float3 zeroed_float3 = {0.0f, 0.0f, 0.0f};
__constant float2 zeroed_float2 = {0.0f, 0.0f};
__constant int4 zeroed_int4     = {0, 0, 0, 0};
__constant int3 zeroed_int3     = {0, 0, 0};
__constant int2 zeroed_int2     = {0, 0};

// =========================================================================
// ============================ OCTREE CONSTANTS ===========================

// (X, Y, Z) mask for the idx
__constant const uchar idx_set_x_mask = 0x1;
__constant const uchar idx_set_y_mask = 0x2;
__constant const uchar idx_set_z_mask = 0x4;
__constant const uchar3 idx_set_mask = {0x1, 0x2, 0x4};

__constant const uchar mask_8[8] = {
	0x1,  0x2,  0x4,  0x8,
	0x10, 0x20, 0x40, 0x80
};

// Mask for counting the previous valid bits
__constant const uchar count_mask_8[8] = {
	0x1,  0x3,  0x7,  0xF,
	0x1F, 0x3F, 0x7F, 0xFF
};

// uint64_t manipulation masks
__constant const ulong child_pointer_mask = 0x0000000000007fff;
__constant const ulong far_bit_mask = 0x8000;
__constant const ulong valid_mask = 0xFF0000;
__constant const ulong leaf_mask = 0xFF000000;
__constant const ulong contour_pointer_mask = 0xFFFFFF00000000;
__constant const ulong contour_mask = 0xFF00000000000000;

// =========================================================================
// ========================= RAYCASTER CONSTANTS ===========================

constant float4 fog_color = { 0.0f, 0.0f, 0.0f, 0.0f };
constant float4 overshoot_color = { 0.00f, 0.00f, 0.00f, 0.00f };
constant float4 overshoot_color_2 = { 0.00f, 0.00f, 0.00f, 0.00f };

// =========================================================================
// =========================================================================


#define setting(name)    settings_buffer[name]



// =========================================================================
// ========================= HELPER FUNCTIONS ==============================

// Phong + diffuse lighting function for g
//  0  1  2  3  4  5  6  7   8   9
// {r, g, b, i, x, y, z, x', y', z'}

float4 view_light(float4 in_color, float3 light, float4 light_color, float3 view, int3 mask) {

	if (all(light == zeroed_float3))
		return zeroed_float4;

	float d = fast_length(light) * 0.01f;
	d *= d;

	float diffuse = max(dot(normalize(convert_float3(mask)), normalize(light)), 0.1f);
	float specular = 0.0f;

	if (diffuse > 0.0f)	{
		// Small dots of light are caused by floating point error
		// flipping bits on the face mask and screwing up this calculation
		float3 halfwayVector = normalize(normalize(light) + normalize(view));
		float specTmp = max(dot(normalize(convert_float3(mask)), halfwayVector), 0.0f);
		specular = pow(specTmp, 1.0f);
	}

	in_color += diffuse * light_color + specular * light_color / d;
	return in_color;
}


int rand(int* seed) // 1 <= *seed < m
{
	int const a = 16807; //ie 7**5
	int const m = 2147483647; //ie 2**31-1

	*seed = ((*seed) * a) % m;
	return(*seed);
}

// =========================================================================
// ========================= OCTREE TRAVERSAL ==============================

struct TraversalState {
int3 sub_oct_pos;
	// 0 being the root node
	int parent_stack_position;
	// Holds child descriptors and their indices in the oct array
	ulong parent_stack[8];
	ulong parent_stack_index[8];

	// 0 being the root node
	uchar scale;
	uchar idx_stack[8];

	// current child descriptor for this node
	ulong current_descriptor;
	ulong current_descriptor_index;

	// The position of the (0,0)th vox in an oct
	int3 oct_pos;

	// The width in voxels of the current valid masks being tested
	int resolution;

	// ====== DEBUG =======
	char found;
};

struct TraversalState get_oct_vox(
	int3 position,
	global ulong *octree_descriptor_buffer,
	global uint *octree_attachment_lookup_buffer,
	global ulong *octree_attachment_buffer,
	global ulong *settings_buffer
){

	struct TraversalState ts;

	ts.current_descriptor_index = setting(OCTREE_ROOT_INDEX);
	ts.current_descriptor = octree_descriptor_buffer[ts.current_descriptor_index];

	ts.scale = 0;
	ts.parent_stack_position = 0;
	ts.found = false;

	// push the root node to the parent stack
	ts.parent_stack[0] = ts.current_descriptor;
	ts.parent_stack_index[0] = ts.current_descriptor_index;

	// Set our initial dimension and the position at the corner of the oct to keep track of our position
	int dimension = setting(OCTDIM);
	ts.resolution = dimension/2;
	ts.oct_pos = zeroed_int3;
	ts.sub_oct_pos = ts.oct_pos;

	// While we are not at the required resolution
	//		Traverse down by setting the valid/leaf mask to the subvoxel
	//		Check to see if it is valid
	//			Yes?
	//				Check to see if it is a leaf
	//				No? Break
	//				Yes? Scale down to the next hierarchy, push the parent to the stack
	//			No?
	//				Break
	while (dimension > 1) {

		ts.oct_pos = ts.sub_oct_pos;

		//	Do the logic steps to find which sub oct we step down into
	    uchar3 masks = select((uchar3)(0, 0, 0),
							   (uchar3)(idx_set_x_mask, idx_set_y_mask, idx_set_z_mask),
							   convert_char3(position >= (int3)(dimension/2) + ts.oct_pos));

		// So we can be a little bit tricky here and increment our
   		// array index that holds our masks as we build the idx.
   		// Adding 1 for X, 2 for Y, and 4 for Z
		ts.idx_stack[ts.scale] = masks.x | masks.y | masks.z;

		// Set our voxel position to the (0,0) of the correct oct by rerunning the logic step
		ts.sub_oct_pos += select((int3)(0), (int3)(dimension/2), position >= (int3)(dimension/2) + ts.oct_pos);

		int mask_index = ts.idx_stack[ts.scale];

		// Check to see if we are on a valid oct / vox
		if ((ts.current_descriptor >> 16) & mask_8[mask_index]) {

			// Check to see if it is a leaf
			if ((ts.current_descriptor >> 24) & mask_8[mask_index]) {

				// If it is, then we cannot traverse further as CP's won't have been generated
				ts.found = true;

				// Early exit, dimension and resolution are not updated
				return ts;
			}



			// If all went well and we found a valid non-leaf oct then we will traverse further down the hierarchy
			ts.scale++;
			ts.parent_stack_position++;
			dimension /= 2;
			ts.resolution /= 2;

			// Count the number of valid octs that come before and add it to the index to get the position
			// Negate it by one as it counts itself
			int count = popcount((uchar)(ts.current_descriptor >> 16) & count_mask_8[mask_index]) - 1;

			// access the far pointer at which the head points too. Determine it's value, and add
			// a count of the valid bits to the index
			if (far_bit_mask & octree_descriptor_buffer[ts.current_descriptor_index]) {
				int far_pointer_index = ts.current_descriptor_index + (ts.current_descriptor & child_pointer_mask);
				ts.current_descriptor_index = octree_descriptor_buffer[far_pointer_index] + count;
			}
			// access the element at which head points to and then add the specified number of indices
			// to get to the correct child descriptor
			else {
				ts.current_descriptor_index = ts.current_descriptor_index + (ts.current_descriptor & child_pointer_mask) + count;
			}

			// Set the current descriptor with the calculated descriptor index
			ts.current_descriptor = octree_descriptor_buffer[ts.current_descriptor_index];

			// And update the data structure with the descriptor and it's index
			ts.parent_stack[ts.parent_stack_position] = ts.current_descriptor;
			ts.parent_stack_index[ts.parent_stack_position] = ts.current_descriptor_index;
		}
		else {
			// If the oct was not valid, then no CP's exists any further
			// This implicitly says that if it's non-valid then it must be a leaf!!

			// Parent stack is only populated up to the current descriptors parent.
			// So that would be the current voxels grandparent
			ts.found = 0;
			return ts;
		}
	}
	ts.found = 1;
	return ts;
}

// =========================================================================
// ========================= RAYCASTER ENTRY ===============================

__kernel void raycaster(
	global char* map,
	constant int3* map_dim,
	constant int2* resolution,
	global float3* projection_matrix,
	global float2* cam_dir,
	global float3* cam_pos,
	global float* lights,
	global int* light_count,
	__write_only image2d_t image,
	__read_only image2d_t texture_atlas,
	constant int2 *atlas_dim,
	constant int2 *tile_dim,
	global ulong *octree_descriptor_buffer,
	global uint *octree_attachment_lookup_buffer,
	global ulong *octree_attachment_buffer,
	global ulong *settings_buffer
){

	// Get the pixel on the viewport, and find the view matrix ray that matches it
	int2 pixel = (int2)(get_global_id(0), get_global_id(1));
    float3 ray_dir = projection_matrix[pixel.x + (*resolution).x * pixel.y];

	// Pitch
	ray_dir = (float3)(
		ray_dir.z * sin((*cam_dir).x) + ray_dir.x * cos((*cam_dir).x),
		ray_dir.y,
		ray_dir.z * cos((*cam_dir).x) - ray_dir.x * sin((*cam_dir).x)
	);

	// Yaw
    ray_dir = (float3)(
		ray_dir.x * cos((*cam_dir).y) - ray_dir.y * sin((*cam_dir).y),
		ray_dir.x * sin((*cam_dir).y) + ray_dir.y * cos((*cam_dir).y),
		ray_dir.z
    );

	if (any(ray_dir == zeroed_float3))
		return;

	// Setup the voxel step based on what direction the ray is pointing
	//                Correct opencl for being stupid and giving us negative for true
	int3 voxel_step = (-1, -1, -1) * ((ray_dir > 0) - (ray_dir < 0));

	// Setup the voxel coords from the camera origin
	// rtn = round towards negative
	int3 voxel = convert_int3_rtn(*cam_pos);
	int3 prev_voxel = voxel;

	// Delta T is the units a ray must travel along an axis in order to
	// traverse an integer split
	float3 delta_t = fabs(1.0f / ray_dir);

	// Intersection T is the collection of the next intersection points
	// for all 3 axis XYZ. We want to 'boost' the intersection_t start point up to
	// the offset, so we get the -(difference) between the int voxel position and the
	// float camera position.
	float3 offset = delta_t * ((*cam_pos) - floor(*cam_pos));

	// Now we apply the inverse of the ray sign. This gives us a negative
	// offset for positive values and vis versa.
	float3 intersection_t = offset * -convert_float3(voxel_step);

	// For negative ray directions the positive value is the correct initial offset
	// For positive rays we now just have to add the delta_t to the negative offset
	// and that will give us the correct positive intersection_t. Don't forget to
	// correct the stupid -1==true
	intersection_t += delta_t * -1 * convert_float3(isless(intersection_t, 0));

	int distance_traveled = 0;
	int max_distance = 20;
	uint bounce_count = 0;
	int3 face_mask = { 0, 0, 0 };
	int voxel_data = 0;
	float3 face_position = zeroed_float3;
	float4 voxel_color= zeroed_float4;
	float2 tile_face_position = zeroed_float2;
	float3 sign = zeroed_float3;
	float4 color_accumulator = zeroed_float4;
	float fog_distance = 0.0f;

	bool shadow_ray = false;
	int vox_dim = setting(OCTDIM);

	struct TraversalState traversal_state;

	traversal_state = get_oct_vox(
			voxel,
			octree_descriptor_buffer,
			octree_attachment_lookup_buffer,
			octree_attachment_buffer,
			settings_buffer);

	int jump_power = traversal_state.resolution;
	int prev_jump_power = jump_power;
	int3 last_oct_pos = (0);

	intersection_t +=
		convert_float3((traversal_state.sub_oct_pos - voxel.xyz) * traversal_state.resolution/2);

	// Andrew Woo's raycasting algo
	while (distance_traveled < max_distance && bounce_count < 2) {

		if (setting(OCTENABLED) == 0) {

			// True will result in a -1, e.g (0, 0, -1) so negate it to positive
			face_mask = -1 * (intersection_t.xyz <= min(intersection_t.yzx, intersection_t.zxy));

			prev_jump_power = jump_power;
			prev_voxel = voxel;

			// not working, wish I would have commented!!!
			voxel.xyz += voxel_step.xyz * face_mask.xyz * convert_int3((traversal_state.sub_oct_pos - voxel.xyz) + traversal_state.resolution);
			//voxel.xyz += voxel_step.xyz * face_mask.xyz * traversal_state.resolution;

			// Test for out of bounds contions, add fog
			if (any(voxel >= *map_dim) || any(voxel < 0)){
				voxel.xyz -= voxel_step.xyz * jump_power * face_mask.xyz;
				color_accumulator = mix(fog_color,  (1.0f,0.3f,0.3f,1.0f), 1.0f) - max(distance_traveled / 8.0f, 0.0f);
				color_accumulator.w = 1.0f;
				break;
			}

			uchar prev_val = traversal_state.idx_stack[traversal_state.scale];
			uchar this_face_mask = 0;

			// Check the voxel face that we traversed, do a select to OR the value out of the three masks
			uchar3 tmp = select((uchar3)(0), (uchar3)(idx_set_x_mask,idx_set_y_mask,idx_set_z_mask), convert_uchar3(face_mask == (1,1,1)));
			this_face_mask = tmp.x | tmp.y | tmp.z;

			// and increment the idx in the idx stack
			traversal_state.idx_stack[traversal_state.scale] ^= this_face_mask;

			// Mask index is the 1D index'd value of the idx for interaction with the valid / leaf masks
			uchar mask_index = traversal_state.idx_stack[traversal_state.scale];

			// If facemask sign is positive, mask_index > prev_val
			// if negative                   mask_index < prev_val
			int3 signed_face_mask = face_mask * voxel_step;
			bool mask_tripped = (mask_index > prev_val) * ((signed_face_mask.x + signed_face_mask.y + signed_face_mask.z) == -1) +
								(mask_index < prev_val) * ((signed_face_mask.x + signed_face_mask.y + signed_face_mask.z) == 1);

			// Whether or not the next oct we want to enter in the current CD's valid mask is 1 or 0
			// Check to see if the idx increased or decreased
			// If it decreased, thus invalid
			//		Pop up the stack until the oct that the idx flip is valid and we landed on a valid oct
			bool is_valid = select(false,
							(bool)(traversal_state.parent_stack[traversal_state.parent_stack_position] >> 16) & mask_8[mask_index],
							mask_tripped == false);



			while ((mask_tripped || !is_valid) && traversal_state.scale >= 1) {

				// Clear and pop the idx stack
				traversal_state.idx_stack[traversal_state.scale] = 0;

				// Clear and pop the parent stack
				traversal_state.parent_stack_index[traversal_state.parent_stack_position] = 0;
				traversal_state.parent_stack[traversal_state.parent_stack_position] = 0;

				// Scale is now set to the oct above. Be wary of this
				jump_power *= 2;
				traversal_state.scale--;
				traversal_state.parent_stack_position--;

				// Keep track of the 0th edge of our current oct, while keeping
				// track of the sub_oct we're coming from
				//traversal_state.sub_oct_pos = traversal_state.oct_pos;

				// Update the prev_val for our new idx
				prev_val = traversal_state.idx_stack[traversal_state.scale];

				// Use the prev val to subtract out the sub oct we were in to get to our oct pos
				// select take the dumb MSB truth value for vector types
				// so we just gotta do this component wise, dumb
				traversal_state.oct_pos.x -= select(0, jump_power, (prev_val & idx_set_x_mask));
				traversal_state.oct_pos.y -= select(0, jump_power, (prev_val & idx_set_y_mask));
				traversal_state.oct_pos.z -= select(0, jump_power, (prev_val & idx_set_z_mask));

				// Set the current CD to the one on top of the stack
				traversal_state.current_descriptor =
					traversal_state.parent_stack[traversal_state.parent_stack_position];

				// Apply the face mask to the new idx for the while check
				traversal_state.idx_stack[traversal_state.scale] ^= this_face_mask;

				// Get the mask index of the new idx and check the valid status
				mask_index = traversal_state.idx_stack[traversal_state.scale];
				is_valid = (traversal_state.parent_stack[traversal_state.parent_stack_position] >> 16) & mask_8[mask_index];

// TODO : SOMETHING WEIRD GOING ON HERE. Line skipping and forgetful while loop. Might be this statement

				// Check to see if the mask tripped, this will override the is_valid on the while loop
				mask_tripped = (mask_index > prev_val) * ((signed_face_mask.x + signed_face_mask.y + signed_face_mask.z) == -1) +
									(mask_index < prev_val) * ((signed_face_mask.x + signed_face_mask.y + signed_face_mask.z) == 1);

			}


			// At this point parent_stack[position] is at the CD of an oct with a
			// valid oct at the leaf indicated by the current idx in the idx stack scale

			// While we haven't bottomed out and the oct we're looking at is valid
			while (jump_power > 1 && is_valid) {

				// If all went well and we found a valid non-leaf oct then we will traverse further down the hierarchy

				// Count the number of valid octs that come before and add it to the index to get the position
				// Negate it by one as it counts itself
				int count = popcount((uchar)(traversal_state.parent_stack[traversal_state.parent_stack_position] >> 16) & count_mask_8[mask_index]) - 1;

				// If this CD had the far bit set
				if (far_bit_mask & octree_descriptor_buffer[traversal_state.parent_stack_index[traversal_state.parent_stack_position]]) {

					// access the far point at which the head points too. Determine it's value, and add
					// the count of the valid bits in the current CD to the index
					uint far_pointer_index =
						traversal_state.parent_stack_index[traversal_state.parent_stack_position] + // current index +
						(traversal_state.parent_stack[traversal_state.parent_stack_position] & child_pointer_mask); // the relative prt to the far ptr

					// Get the absolute ptr from the far ptr and add the count to get the CD that we want
					traversal_state.parent_stack_index[traversal_state.parent_stack_position + 1] = octree_descriptor_buffer[far_pointer_index] + count;
				}
				// If this CD doesn't have the far bit set, access the element at which head points to
				// and then add the specified number of indices to get to the correct child descriptor
				else {
					traversal_state.parent_stack_index[traversal_state.parent_stack_position + 1] =
						traversal_state.parent_stack_index[traversal_state.parent_stack_position] + // The current index to this CD
						(traversal_state.parent_stack[traversal_state.parent_stack_position] & child_pointer_mask) + count; // The relative dist + the number of bits that were valid
				}

				// Now that we have the index set we can increase our parent stack position to the next level and
				// retrieve the value of its CD
				traversal_state.parent_stack_position++;
				traversal_state.parent_stack[traversal_state.parent_stack_position] = octree_descriptor_buffer[traversal_state.parent_stack_index[traversal_state.parent_stack_position]];


				// Unlike the single shot DFS, we inherited a valid idx from the upwards traversal. So now we must
				// set the idx at the tail end of this for loop
				// Do the logic steps to find which sub oct we step down into
				uchar3 masks = select((uchar3)(0, 0, 0),
							   (uchar3)(idx_set_x_mask, idx_set_y_mask, idx_set_z_mask),
							   convert_char3(voxel >= (int3)(jump_power) + traversal_state.oct_pos));
				traversal_state.oct_pos += select((int3)(0), (int3)(jump_power), voxel >= (int3)(jump_power) + traversal_state.oct_pos);

				jump_power /= 2;

			 	// Update the mask index with the new voxel we walked down to, and then check it's valid status
				mask_index = traversal_state.idx_stack[traversal_state.scale];
				is_valid = (traversal_state.parent_stack[traversal_state.parent_stack_position] >> 16) & mask_8[mask_index];

				traversal_state.scale++;
			}
			traversal_state.sub_oct_pos = traversal_state.oct_pos;

			uchar3 masks = select((uchar3)(0, 0, 0),
								   (uchar3)(idx_set_x_mask, idx_set_y_mask, idx_set_z_mask),
								   convert_char3(voxel >= (int3)(jump_power) + traversal_state.oct_pos));

			// So we can be a little bit tricky here and increment our
			// array index that holds our masks as we build the idx.
			// Adding 1 for X, 2 for Y, and 4 for Z
			traversal_state.idx_stack[traversal_state.scale] = masks.x | masks.y | masks.z;

			// Set our voxel position to the (0,0) of the correct oct by rerunning the logic step
			traversal_state.sub_oct_pos += select((int3)(0), (int3)(jump_power), voxel >= (int3)(jump_power) + traversal_state.oct_pos);

			// Add the delta for the jump power and the traversed face
			intersection_t += delta_t * jump_power * fabs(convert_float3(face_mask.xyz));

			// Get the other faces
			//int3 other_faces = select((int3)(1,1,1), (int3)(0,0,0), (int3)(face_mask == 1));

			// Get the amount of times we need to multiply the delta t to get to our face
			//uint3 multiplier = convert_uint3(abs(traversal_state.oct_pos - last_oct_pos) * (1.0f/prev_jump_power));

			//last_oct_pos = traversal_state.oct_pos;


			// Go back to the beginning intersection t's for the non traversed faces
			//intersection_t -= delta_t * prev_jump_power * convert_float3(other_faces.xyz);

			// add back the intersection for our current jump power
			//intersection_t += delta_t * convert_float3(multiplier) * jump_power * fabs(convert_float3(other_faces.xyz));

			// if (traversal_state.scale == 1 && is_valid){
			// 	voxel_data = 5;
			// 	//voxel.xyz -= voxel_step.xyz * face_mask.xyz;
			// 	color_accumulator = mix((1.0f, 1.0f, 1.0f, 1.0f), (1.0f, 1.0f, 1.0f, 1.0f), 1.0f - max(distance_traveled / 700.0f, 0.0f));
			// 	color_accumulator.w *= 4;
			// 	break;
			// }
			//voxel_data = map[voxel.x + (*map_dim).x * (voxel.y + (*map_dim).z * (voxel.z))];
		}

// =======================================================================
//
// =======================================================================
		else {

			// True will result in a -1, e.g (0, 0, -1) so negate it to positive
			face_mask = -1 * (intersection_t.xyz <= min(intersection_t.yzx, intersection_t.zxy));
			intersection_t += delta_t * convert_float3(face_mask.xyz);
			voxel.xyz += voxel_step.xyz * face_mask.xyz;

			// Test for out of bounds contions, add fog
			if (any(voxel >= *map_dim) || any(voxel < 0)){
				voxel.xyz -= voxel_step.xyz * face_mask.xyz;
				color_accumulator = mix(fog_color, voxel_color, 1.0f - max(distance_traveled / 700.0f, 0.0f));
				color_accumulator.w *= 4;
				break;
			}
			voxel_data = map[voxel.x + (*map_dim).x * (voxel.y + (*map_dim).z * (voxel.z))];
		}
// =======================================================================
//
// =======================================================================

		if (voxel_data == 5 || voxel_data == 6) {

			// Determine where on the 2d plane the ray intersected
			face_position = zeroed_float3;
			tile_face_position = zeroed_float2;

			// Collect the sign of the face hit for ray redirection
			sign = (1.0f, 1.0f, 1.0f);

			// First determine the percent of the way the ray is towards the next intersection_t
			// in relation to the xyz position on the plane
			if (face_mask.x == 1) {

				sign.x *= -1.0;

				// the next intersection for this plane - the last intersection of the passed plane / delta of this plane
				// basically finds how far in on the other 2 axis we are when the ray traversed the plane
				float z_percent = (intersection_t.z - (intersection_t.x - delta_t.x)) / delta_t.z;
				float y_percent = (intersection_t.y - (intersection_t.x - delta_t.x)) / delta_t.y;

				// Since we intersected face x, we know that we are at the face (1.0)
				// I think the 1.001f rendering bug is the ray thinking it's within the voxel
				// even though it's sitting on the very edge
				face_position = (float3)(1.00001f, y_percent, z_percent);
				tile_face_position = face_position.yz;
			}
			else if (face_mask.y == 1) {

				sign.y *= -1.0;
				float x_percent = (intersection_t.x - (intersection_t.y - delta_t.y)) / delta_t.x;
				float z_percent = (intersection_t.z - (intersection_t.y - delta_t.y)) / delta_t.z;
				face_position = (float3)(x_percent, 1.00001f, z_percent);
				tile_face_position = face_position.xz;
			}

			else if (face_mask.z == 1) {

				sign.z *= -1.0;
				float x_percent = (intersection_t.x - (intersection_t.z - delta_t.z)) / delta_t.x;
				float y_percent = (intersection_t.y - (intersection_t.z - delta_t.z)) / delta_t.y;
				face_position = (float3)(x_percent, y_percent, 1.00001f);
				tile_face_position = face_position.xy;

			}

			// Because the raycasting process is agnostic to the quadrant
			// it's working in, we need to transpose the sign over to the face positions.
			// If we don't it will think that it is always working in the (1, 1, 1) quadrant
			// and will just "copy" the quadrant. This includes shadows as they use the face_position
			// in order to cast the intersection ray!!

			face_position.x = select((face_position.x), (-face_position.x + 1.0f), (int)(ray_dir.x > 0));
			tile_face_position.x = select((tile_face_position.x), (-tile_face_position.x + 1.0f), (int)(ray_dir.x < 0));

			if (ray_dir.y > 0){
				face_position.y =  -face_position.y + 1;
			} else {
				tile_face_position.x = 1.0 - tile_face_position.x;

				// We run into the Hairy ball problem, so we need to define
				// a special case for the zmask
				if (face_mask.z == 1) {
					tile_face_position.x = 1.0f - tile_face_position.x;
					tile_face_position.y = 1.0f - tile_face_position.y;
				}
			}

			face_position.z = select((face_position.z), (-face_position.z + 1.0f), -1 * (int)(ray_dir.z > 0));
			tile_face_position.y = select((tile_face_position.y), (-tile_face_position.y + 1.0f), -1 * (int)(ray_dir.z < 0));

			// Now we detect what type of of voxel we intersected and decide whether
			// to bend the ray, send out a light intersection ray, or add texture color

			// TEXTURE HIT + SHADOW RAY REDIRECTION
			if (voxel_data == 5 && !shadow_ray){

				shadow_ray = true;
				voxel_color.xyz += (float3)read_imagef(
						 texture_atlas,
						 convert_int2(tile_face_position * convert_float2(*atlas_dim / *tile_dim)) +
						 convert_int2((float2)(5, 0) * convert_float2(*atlas_dim / *tile_dim))
				).xyz/2;

				color_accumulator = view_light(
							voxel_color,
							(convert_float3(voxel) + face_position) - (float3)(lights[4], lights[5], lights[6]),
							(float4)(lights[0], lights[1], lights[2], lights[3]),
							(convert_float3(voxel) + face_position) - (*cam_pos),
							face_mask * voxel_step
				);

				fog_distance = distance_traveled;
				max_distance = distance_traveled + fast_distance(convert_float3(voxel), (float3)(lights[4], lights[5], lights[6]));

				float3 hit_pos = convert_float3(voxel) + face_position;
				ray_dir = normalize((float3)(lights[4], lights[5], lights[6]) - hit_pos);
				if (any(ray_dir == zeroed_float3))
					return;

				voxel -= voxel_step * face_mask;
				voxel_step = ( -1, -1, -1 ) * ((ray_dir > 0) - (ray_dir < 0));

				delta_t = fabs(1.0f / ray_dir);
				intersection_t = delta_t * ((hit_pos) - floor(hit_pos)) * convert_float3(voxel_step);
				intersection_t += delta_t * -convert_float3(isless(intersection_t, 0));

			// REFLECTION
			} else if (voxel_data == 6 && !shadow_ray) {

				voxel_color.xyz += (float3)read_imagef(
						 texture_atlas,
						 convert_int2(tile_face_position * convert_float2(*atlas_dim / *tile_dim)) +
						 convert_int2((float2)(3, 4) * convert_float2(*atlas_dim / *tile_dim))
				).xyz/4;

				voxel_color.w -= 0.0f;

				float3 hit_pos = convert_float3(voxel) + face_position;
				ray_dir *= sign;
				if (any(ray_dir == zeroed_float3))
					return;

				voxel -= voxel_step * face_mask;
				voxel_step = ( -1, -1, -1 ) * (ray_dir > 0) - (ray_dir < 0);

				delta_t = fabs(1.0f / ray_dir);
				intersection_t = delta_t * ((hit_pos)-floor(hit_pos)) * convert_float3(voxel_step);
				intersection_t += delta_t * -convert_float3(isless(intersection_t, 0));

				bounce_count += 1;

			// SHADOW RAY HIT
			} else {
				color_accumulator.w = 0.1f;
				break;
			}
		}

		// At the bottom of the while loop, add one to the distance ticker
		distance_traveled++;
    }
	color_accumulator = mix(fog_color, color_accumulator, 1.0f - max(fog_distance / 700.0f, 0.0f));
	write_imagef(
		image,
		pixel,
		color_accumulator
	);

    return;
}
