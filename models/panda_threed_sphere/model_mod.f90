! DART software - Copyright UCAR. This open source software is provided
! by UCAR, "as is", without charge, subject to all terms of use at
! http://www.image.ucar.edu/DAReS/DART/DART_download
!

module model_mod

! This is a template model for adding and running pathological tests for
! threed_sphere location modules. Modify the provided panda_restart input file, 
! panda_nml test configuration file, and this model_mod inferface as needed. 
! Examples of pathological test cases are provided in static_init_model.
! Do not change the arguments for the public routines.

use        types_mod, only : r8, i8, MISSING_R8

use time_manager_mod, only : time_type, set_time

use     location_mod, only : location_type, get_close_type, &
                             loc_get_close_obs => get_close_obs, &
                             loc_get_close_state => get_close_state, &
                             set_location, set_location_missing, &
                             VERTISUNDEF

use    utilities_mod, only : register_module, error_handler, &
                             E_ERR, E_MSG, &
                             nmlfileunit, do_output, do_nml_file, do_nml_term,  &
                             find_namelist_in_file, check_namelist_read

use netcdf_utilities_mod, only : nc_add_global_attribute, nc_synchronize_file, &
                                 nc_add_global_creation_time, &
                                 nc_begin_define_mode, nc_end_define_mode, &
                                 nc_open_file_readonly, nc_get_dimension_size, &
                                 nc_get_variable, nc_close_file

use        obs_kind_mod,  only : QTY_STATE_VARIABLE

use state_structure_mod,  only : add_domain, get_domain_size, &
                                 get_model_variable_indices

use ensemble_manager_mod, only : ensemble_type

! These routines are passed through from default_model_mod.
! To write model specific versions of these routines
! remove the routine from this use statement and add your code to
! this the file.
use default_model_mod, only : pert_model_copies, read_model_time, write_model_time, &
                              init_time => fail_init_time, &
                              init_conditions => fail_init_conditions, &
                              convert_vertical_obs, convert_vertical_state, adv_1step

implicit none
private

! routines required by DART code - will be called from filter and other
! DART executables. 
public :: get_model_size,         &
          get_state_meta_data,    &
          model_interpolate,      &
          end_model,              &
          static_init_model,      &
          nc_write_model_atts,    &
          get_close_obs,          &
          get_close_state,        &
          pert_model_copies,      &
          convert_vertical_obs,   &
          convert_vertical_state, &
          read_model_time,        &
          adv_1step,              &
          init_time,              &
          init_conditions,        &
          shortest_time_between_assimilations, &
          write_model_time

!------------------------------------------------------------------
! default pathological test namelist options

logical :: PT_module_init           = .false.
logical :: PT_neg_assim_time_step   = .false.
logical :: PT_invalid_template_file = .false.
logical :: PT_add_domain_mismatch   = .false.
logical :: PT_add_domain_loop       = .false.
integer :: PT_add_domain_nloops     = 1
logical :: PT_invalid_model_size    = .false.
integer :: PT_model_size            = -1

namelist /panda_nml/ PT_module_init, PT_neg_assim_time_step, &
                     PT_invalid_template_file, &
                     PT_add_domain_mismatch, PT_add_domain_loop, &
                     PT_add_domain_nloops, PT_invalid_model_size, &
                     PT_model_size


character(len=256), parameter :: source   = "model_mod.f90"
logical :: module_initialized = .false.
integer :: dom_id ! used to access the state structure
type(time_type) :: assimilation_time_step 

!------------------------------------------------------------------
! model grid information

integer               :: nlon, nlat, ntemps
! Grid info, indexing into each contains the lon/lat at grid point.
real(r8), allocatable :: lons(:), lats(:)
! Plain temperature values - index corresponds to lats, lons index 
real(r8), allocatable :: temperatures(:)

integer(i8) :: model_size ! length of state vector
integer     :: nfields    ! number of variables in state

! Example Namelist
! Use the namelist for options to be set at runtime.
character(len=256) :: template_file = 'panda_restart.nc'
integer  :: time_step_days      = 0
integer  :: time_step_seconds   = 3600

character(len=512) :: string1, string2

namelist /model_nml/ template_file, time_step_days, time_step_seconds

contains

!------------------------------------------------------------------
!
! Called to do one time initialization of the model. As examples,
! might define information about the model size or model timestep.
! In models that require pre-computed static data, for instance
! spherical harmonic weights, these would also be computed here.
!
! This routine has been modified with example pathological tests.
! Tests are triggered from the panda_threed.nml file.

subroutine static_init_model()

integer  :: iunit, io, i

! Find and read pathological test options namelist
call find_namelist_in_file("panda_threed.nml", "panda_nml", iunit)
read(iunit, nml = panda_nml, iostat = io)
call check_namelist_read(iunit, io, "panda_nml")

module_initialized = PT_module_init

! Print module information to log file and stdout.
call register_module(source)

call find_namelist_in_file("input.nml", "model_nml", iunit)
read(iunit, nml = model_nml, iostat = io)
call check_namelist_read(iunit, io, "model_nml")

! Record the namelist values used for the run 
if (do_nml_file()) write(nmlfileunit, nml=model_nml)
if (do_nml_term()) write(     *     , nml=model_nml)

! This time is both the minimum time you can ask the model to advance
! (for models that can be advanced by filter) and it sets the assimilation
! window.  All observations within +/- 1/2 this interval from the current
! model time will be assimilated. If this is not settable at runtime 
! feel free to hardcode it and remove from the namelist.

if (PT_neg_assim_time_step) then
    time_step_seconds = -1
    time_step_days    = -1
end if

assimilation_time_step = set_time(time_step_seconds, &
                                  time_step_days)

if (PT_invalid_template_file) template_file = 'invalid_file'

! Define which variables are in the model state
do i = 1, PT_add_domain_nloops
    dom_id = add_domain(template_file, num_vars=1, &
                              var_names=(/'temp'/), &
                              kind_list=(/0/))
end do

if (PT_invalid_model_size) then
    model_size = PT_model_size
else
    model_size = get_domain_size(dom_id)
end if

call read_panda_definitions(template_file)


end subroutine static_init_model

!------------------------------------------------------------------
! Returns the number of items in the state vector as an integer. 

function get_model_size()

integer(i8) :: get_model_size

if ( .not. module_initialized ) call static_init_model

get_model_size = model_size

end function get_model_size


!------------------------------------------------------------------
! Given a state handle, a location, and a state quantity,
! interpolates the state variable fields to that location and returns
! the values in expected_obs. The istatus variables should be returned as
! 0 unless there is some problem in computing the interpolation in
! which case a positive istatus should be returned.
!
! For applications in which only perfect model experiments
! with identity observations (i.e. only the value of a particular
! state variable is observed), this can be a NULL INTERFACE.

subroutine model_interpolate(state_handle, ens_size, location, qty, expected_obs, istatus)

type(ensemble_type), intent(in) :: state_handle
integer,             intent(in) :: ens_size
type(location_type), intent(in) :: location
integer,             intent(in) :: qty
real(r8),           intent(out) :: expected_obs(ens_size) !< array of interpolated values
integer,            intent(out) :: istatus(ens_size)

if ( .not. module_initialized ) call static_init_model

! This should be the result of the interpolation of a
! given kind (itype) of variable at the given location.
! expected_obs(:) = MISSING_R8
expected_obs(:) = 0.0
! istatus for successful return should be 0. 
! Any positive number is an error.
! Negative values are reserved for use by the DART framework.
! Using distinct positive values for different types of errors can be
! useful in diagnosing problems.
istatus(:) = 0

end subroutine model_interpolate



!------------------------------------------------------------------
! Returns the smallest increment in time that the model is capable 
! of advancing the state in a given implementation, or the shortest
! time you want the model to advance between assimilations.

! - return blank time_type?

function shortest_time_between_assimilations()

type(time_type) :: shortest_time_between_assimilations

if ( .not. module_initialized ) call static_init_model

shortest_time_between_assimilations = assimilation_time_step

end function shortest_time_between_assimilations



!------------------------------------------------------------------
! Given an integer index into the state vector, returns the
! associated location and optionally the physical quantity.

subroutine get_state_meta_data(index_in, location, qty)

integer(i8),         intent(in)  :: index_in
type(location_type), intent(out) :: location
integer,             intent(out), optional :: qty

integer  :: lon_index, lat_index, lev_index

real(r8) :: lat, lon

if ( .not. module_initialized ) call static_init_model

call get_model_variable_indices(index_in, lon_index, lat_index, lev_index, kind_index=qty)

location = set_location(lons(lon_index), lats(lat_index), MISSING_R8, VERTISUNDEF)

! should be set to the physical quantity, e.g. QTY_TEMPERATURE
if (present(qty)) qty = QTY_STATE_VARIABLE

end subroutine get_state_meta_data


!------------------------------------------------------------------
! Any model specific distance calcualtion can be done here

subroutine get_close_obs(gc, base_loc, base_type, locs, loc_qtys, loc_types, &
                         num_close, close_ind, dist, ens_handle)

type(get_close_type),          intent(in)    :: gc            ! handle to a get_close structure
integer,                       intent(in)    :: base_type     ! observation TYPE
type(location_type),           intent(inout) :: base_loc      ! location of interest
type(location_type),           intent(inout) :: locs(:)       ! obs locations
integer,                       intent(in)    :: loc_qtys(:)   ! QTYS for obs
integer,                       intent(in)    :: loc_types(:)  ! TYPES for obs
integer,                       intent(out)   :: num_close     ! how many are close
integer,                       intent(out)   :: close_ind(:)  ! incidies into the locs array
real(r8),            optional, intent(out)   :: dist(:)       ! distances in radians
type(ensemble_type), optional, intent(in)    :: ens_handle

character(len=*), parameter :: routine = 'get_close_obs'

call loc_get_close_obs(gc, base_loc, base_type, locs, loc_qtys, loc_types, &
                          num_close, close_ind, dist, ens_handle)

end subroutine get_close_obs


!------------------------------------------------------------------
! Any model specific distance calcualtion can be done here
subroutine get_close_state(gc, base_loc, base_type, locs, loc_qtys, loc_indx, &
                           num_close, close_ind, dist, ens_handle)

type(get_close_type),          intent(in)    :: gc           ! handle to a get_close structure
type(location_type),           intent(inout) :: base_loc     ! location of interest
integer,                       intent(in)    :: base_type    ! observation TYPE
type(location_type),           intent(inout) :: locs(:)      ! state locations
integer,                       intent(in)    :: loc_qtys(:)  ! QTYs for state
integer(i8),                   intent(in)    :: loc_indx(:)  ! indices into DART state vector
integer,                       intent(out)   :: num_close    ! how many are close
integer,                       intent(out)   :: close_ind(:) ! indices into the locs array
real(r8),            optional, intent(out)   :: dist(:)      ! distances in radians
type(ensemble_type), optional, intent(in)    :: ens_handle

character(len=*), parameter :: routine = 'get_close_state'


call loc_get_close_state(gc, base_loc, base_type, locs, loc_qtys, loc_indx, &
                            num_close, close_ind, dist, ens_handle)


end subroutine get_close_state


!------------------------------------------------------------------
! Does any shutdown and clean-up needed for model. Can be a NULL
! INTERFACE if the model has no need to clean up storage, etc.

subroutine end_model()


end subroutine end_model


!------------------------------------------------------------------
! write any additional attributes to the output and diagnostic files

subroutine nc_write_model_atts(ncid, domain_id)

integer, intent(in) :: ncid      ! netCDF file identifier
integer, intent(in) :: domain_id

if ( .not. module_initialized ) call static_init_model

! put file into define mode.

call nc_begin_define_mode(ncid)

call nc_add_global_creation_time(ncid)

call nc_add_global_attribute(ncid, "model_source", source )
call nc_add_global_attribute(ncid, "model", "template")

call nc_end_define_mode(ncid)

! Flush the buffer and leave netCDF file open
call nc_synchronize_file(ncid)

end subroutine nc_write_model_atts

!------------------------------------------------------------------
! Routines below are private to the module
!------------------------------------------------------------------

subroutine read_panda_definitions(file_name)
! Read panda grid definitions from the panda restart file
! populate module's metadata storage variables
! nlon, lons(:), nlat, lats(:)
!
! note: longitudes are expected to be non-negative

character(len=*), parameter :: routine = 'read_panda_definitions'

character(len=*), intent(in) :: file_name
integer :: ncid, i, j

ncid = nc_open_file_readonly(file_name, routine)

! Load dimension sizes for lon & lat
nlon   = nc_get_dimension_size(ncid, 'lon', routine)
nlat   = nc_get_dimension_size(ncid, 'lat', routine)
ntemps = nc_get_dimension_size(ncid, 'temp', routine)

! Allocate lons & lat arrays with dimension sizes
allocate(lons(nlon))
allocate(lats(nlat))
allocate(temperatures(ntemps))

! Load variable data into module storage
call nc_get_variable(ncid, 'lon', lons, routine)
call nc_get_variable(ncid, 'lat', lats, routine)
call nc_get_variable(ncid, 'temp', temperatures, routine)

call nc_close_file(ncid)

end subroutine read_panda_definitions

!===================================================================
! End of model_mod
!===================================================================
end module model_mod
