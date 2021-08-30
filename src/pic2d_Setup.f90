!-----------------------------------------
!
SUBROUTINE PREPARE_SETUP_VALUES

  USE ParallelOperationValues
  USE CurrentProblemValues

  IMPLICIT NONE

  INTEGER n

  CHARACTER(14) initbo_filename
  LOGICAl exists
  
  CHARACTER(1) buf 

  REAL(8) Te_normal_constant_emit_eV
  REAL(8) Te_parallel_constant_emit_eV
  REAL(8) We_beam_constant_emit_eV

  INTERFACE
     FUNCTION convert_int_to_txt_string(int_number, length_of_string)
       CHARACTER*(length_of_string) convert_int_to_txt_string
       INTEGER int_number
       INTEGER length_of_string
     END FUNCTION convert_int_to_txt_string
  END INTERFACE

  DO n = 1, N_of_boundary_and_inner_objects

     whole_object(n)%material = '      '
     whole_object(n)%phi_const = 0.0_8
     whole_object(n)%phi_var = 0.0_8
     whole_object(n)%omega = 0.0_8
     whole_object(n)%phase = 0.0_8
     whole_object(n)%N_electron_constant_emit = 0.0
     whole_object(n)%model_constant_emit = 0
     whole_object(n)%factor_convert_vinj_normal_constant_emit = 0.0_8
     whole_object(n)%factor_convert_vinj_parallel_constant_emit = 0.0_8
     whole_object(n)%v_ebeam_constant_emit = 0.0_8

     whole_object(n)%use_waveform = .FALSE.

     initbo_filename = 'init_bo_NN.dat'
     initbo_filename(9:10) = convert_int_to_txt_string(n, 2)

     INQUIRE (FILE = initbo_filename, EXIST = exists)
     IF (.NOT.exists) THEN
        IF (Rank_of_process.EQ.0) PRINT '("### PREPARE_SETUP_VALUES :: file ",A14," not found, use default setup values for boundary object ",i2)', initbo_filename, n
        CYCLE
     END IF

     OPEN (9, FILE = initbo_filename)

     READ (9, '(A1)') buf !------AAAAAA--- code/abbreviation of the material, character string 
     READ (9, '(6x,A6)') whole_object(n)%material
     READ (9, '(A1)') buf !---ddddd.ddd--- constant potential [V]
     READ (9, '(3x,f9.3)') whole_object(n)%phi_const
     READ (9, '(A1)') buf !---ddddd.ddd--- amplitude of potential oscillations [V]
     READ (9, '(3x,f9.3)') whole_object(n)%phi_var
     READ (9, '(A1)') buf !---ddddd.ddd--- frequency [MHz]
     READ (9, '(3x,f9.3)') whole_object(n)%omega
     READ (9, '(A1)') buf !---ddddd.ddd--- phase [deg] for sin(omega*t+phase)
     READ (9, '(3x,f9.3)') whole_object(n)%phase
     READ (9, '(A1)') buf !---ddddd.ddd--- number of electron macroparticles injected each timestep, constant [dim-less]
     READ (9, '(3x,f9.3)') whole_object(n)%N_electron_constant_emit
     READ (9, '(A1)') buf !-------d------- emission model (0 = thermal emission, 1 = electron beam)
     READ (9, '(7x,i1)') whole_object(n)%model_constant_emit
     READ (9, '(A1)') buf !----dddd.ddd--- temperature of emitted electrons / half-energy-spread of the beam (Tb) normal to the wall [eV] (>=0)
     READ (9, '(4x,f8.3)') Te_normal_constant_emit_eV
     READ (9, '(A1)') buf !----dddd.ddd--- temperature of emitted electrons parallel to the wall [eV] (>=0)
     READ (9, '(4x,f8.3)') Te_parallel_constant_emit_eV
     READ (9, '(A1)') buf !----dddd.ddd--- energy of the electron beam [eV] (>3Tb/2)
     READ (9, '(4x,f8.3)') We_beam_constant_emit_eV

     CLOSE (9, STATUS = 'KEEP')

     IF (whole_object(n)%model_constant_emit.EQ.0) THEN
! thermal emission
        whole_object(n)%factor_convert_vinj_normal_constant_emit = SQRT(Te_normal_constant_emit_eV / T_e_eV) / N_max_vel
     ELSE
! electron beam
!
! For beam injection, we take velocity from a Maxwellian distribution with certain (see below) temperature, then add the beam velocity.
! We must ensure that particle velocity is directed away from the wall, therefore the beam velocity must exceed 
! 3 thermal velocities for the temperature used to initialize beam particles.
! When the beam is requested, the normal temperature is treated as the scale of energy spread of beam electrons in the laboratory frame.
! In order to achieve this, it is necessary to use a different (smaller) value of temperature at the first step of selecting beam velocities.
! 
! check that the beam energy is above the threshold
        IF (We_beam_constant_emit_eV.LE.(1.5_8 * Te_normal_constant_emit_eV)) THEN
           IF (Rank_of_process.EQ.0) PRINT '("Error in PREPARE_SETUP_VALUES, boundary object ",i2," :: for beam energy ",f8.3," eV the beam energy spread ",f7.3," eV exceeds threshold ",f8.3," eV")', &
                & n, We_beam_constant_emit_eV, Te_normal_constant_emit_eV, We_beam_constant_emit_eV/1.5
           STOP
        END IF
! scaling factor is calculated with a reduced temperature to achieve required energy spread in the beam frame
        whole_object(n)%factor_convert_vinj_normal_constant_emit = SQRT(0.25_8 * Te_normal_constant_emit_eV**2 / (We_beam_constant_emit_eV * T_e_eV)) / N_max_vel
        whole_object(n)%v_ebeam_constant_emit = SQRT(We_beam_constant_emit_eV / T_e_eV) / N_max_vel
     END IF

     whole_object(n)%factor_convert_vinj_parallel_constant_emit = SQRT(Te_parallel_constant_emit_eV / T_e_eV) / N_max_vel

  END DO

  CALL PREPARE_WAVEFORMS
  
END SUBROUTINE PREPARE_SETUP_VALUES

!--------------------------------------------
!
SUBROUTINE PREPARE_WAVEFORMS

  USE ParallelOperationValues, ONLY : Rank_of_process
  USE CurrentProblemValues, ONLY : whole_object, N_of_boundary_and_inner_objects, METAL_WALL, delta_t_s, F_scale_V

  IMPLICIT NONE

  INTEGER n

  CHARACTER(23) initbowf_filename   ! init_bo_NN_waveform.dat
                                    ! ----x----I----x----I---
  LOGICAL exists
  CHARACTER(1) buf
  INTEGER iostatus
  REAL rdummy

  REAL(8) wf_phi_V, wf_nu_Hz
  INTEGER wf_period

  INTEGER ALLOC_ERR
  INTEGER i
  
  INTERFACE
     FUNCTION convert_int_to_txt_string(int_number, length_of_string)
       CHARACTER*(length_of_string) convert_int_to_txt_string
       INTEGER int_number
       INTEGER length_of_string
     END FUNCTION convert_int_to_txt_string
  END INTERFACE

  DO n = 1, N_of_boundary_and_inner_objects

     IF (whole_object(n)%object_type.NE.METAL_WALL) CYCLE 

     initbowf_filename = 'init_bo_NN_waveform.dat'
     initbowf_filename(9:10) = convert_int_to_txt_string(n, 2)

     INQUIRE (FILE = initbowf_filename, EXIST = exists)
     IF (.NOT.exists) CYCLE

     IF (Rank_of_process.EQ.0) PRINT '("### PREPARE_WAVEFORMS :: found file ",A23," for boundary object ",i2," analyzing...")', initbowf_filename, n

     OPEN (11, FILE = initbowf_filename)
     READ (11, '(A1)') buf   ! potential amplitude [V], skip for now
     READ (11, '(A1)') buf   ! frequency [Hz], skip for now
     READ (11, '(A1)') buf   ! comment line, skip
     READ (11, '(A1)') buf   ! comment line, skip
     whole_object(n)%N_wf_points = 0
     DO 
        READ (11, *, iostat = iostatus) rdummy, rdummy
        IF (iostatus.NE.0) EXIT
        whole_object(n)%N_wf_points = whole_object(n)%N_wf_points + 1
     END DO
     CLOSE (11, STATUS = 'KEEP')

     IF (whole_object(n)%N_wf_points.LE.1) THEN
        IF (Rank_of_process.EQ.0) PRINT '("### PREPARE_WAVEFORMS :: WARNING-1 :: not enough (",i4,") valid data points in file ",A23," , waveform for boundary object ",i2," is off ###")', &
             & whole_object(n)%N_wf_points, initbowf_filename,  n
        CYCLE
     END IF

     OPEN (11, FILE = initbowf_filename)
     READ (11, *) wf_phi_V                ! potential amplitude [V]
     READ (11, *) wf_nu_Hz                ! frequency [Hz]

     IF (wf_phi_V.EQ.0.0) THEN
        IF (Rank_of_process.EQ.0) PRINT '("### PREPARE_WAVEFORMS :: WARNING-2 :: zero waveform amplitude in file ",A23," , waveform for boundary object ",i2," is off ###")', initbowf_filename,  n
        CYCLE
     END IF

     wf_period = 1.0_8 / (wf_nu_Hz * delta_t_s) ! in units of time steps
     IF (wf_period.LT.(whole_object(n)%N_wf_points-1)) THEN
        IF (Rank_of_process.EQ.0) &
             & PRINT '("### PREPARE_WAVEFORMS :: WARNING-3 :: in file ",A23," too many points (",i6,") for given waveform period of ",i6," time steps, waveform for boundary object ",i2," is off ###")', &
             & initbowf_filename, whole_object(n)%N_wf_points, wf_period, n
        CYCLE
     END IF

     ALLOCATE (whole_object(n)%wf_T_cntr(1:whole_object(n)%N_wf_points), STAT = ALLOC_ERR)
     ALLOCATE (whole_object(n)%wf_phi(   1:whole_object(n)%N_wf_points), STAT = ALLOC_ERR)

     READ (11, '(A1)') buf   ! comment line, skip
     READ (11, '(A1)') buf   ! comment line, skip
     DO i = 1, whole_object(n)%N_wf_points
        READ (11, *) rdummy, whole_object(n)%wf_phi(i)
        whole_object(n)%wf_T_cntr(i) = INT(rdummy * wf_period)
        whole_object(n)%wf_phi(i) = (wf_phi_V / F_scale_V) * whole_object(n)%wf_phi(i)
     END DO
     CLOSE (11, STATUS = 'KEEP')

! enforce the ends
     whole_object(n)%wf_T_cntr(1) = 0
     whole_object(n)%wf_T_cntr(whole_object(n)%N_wf_points) = wf_period
     whole_object(n)%wf_phi(whole_object(n)%N_wf_points) = whole_object(n)%wf_phi(1)

! enforce increasing times
     DO i = 2, whole_object(n)%N_wf_points-1
         whole_object(n)%wf_T_cntr(i) = MAX(whole_object(n)%wf_T_cntr(i), whole_object(n)%wf_T_cntr(i-1)+1)
     END DO

! final check
     i = whole_object(n)%N_wf_points
     IF (whole_object(n)%wf_T_cntr(i).GT.whole_object(n)%wf_T_cntr(i-1)) THEN
! passed
        IF (Rank_of_process.EQ.0) &
             & PRINT '("### PREPARE_WAVEFORMS :: potential of boundary object ",i2," will be calculated with the waveform  ###")', n
        whole_object(n)%use_waveform = .TRUE.
     ELSE
! did not pass
        IF (Rank_of_process.EQ.0) &
             & PRINT '("### PREPARE_WAVEFORMS :: WARNING-4 :: inconsistent data in file ",A23," , waveform for boundary object ",i2," is off ###")', &
             & initbowf_filename, n
! cleanup
        IF (ALLOCATED(whole_object(n)%wf_T_cntr)) DEALLOCATE(whole_object(n)%wf_T_cntr, STAT = ALLOC_ERR)
        IF (ALLOCATED(whole_object(n)%wf_phi)) DEALLOCATE(whole_object(n)%wf_phi, STAT = ALLOC_ERR)
     END IF

  END DO

END SUBROUTINE PREPARE_WAVEFORMS

!--------------------------------------------
!
SUBROUTINE PERFORM_ELECTRON_EMISSION_SETUP

  USE ParallelOperationValues
  USE CurrentProblemValues
  USE ClusterAndItsBoundaries
  USE SetupValues

  USE rng_wrapper

  IMPLICIT NONE

  INCLUDE 'mpif.h'

  INTEGER ierr

  INTEGER n, m, nwo
  REAL(8) add_N_e_to_emit   !### double precision now, same as the random numbers, fractional part is treated as probability

  INTEGER k
  REAL(8) x, y, vx, vy, vz
  INTEGER tag

  INTEGER, ALLOCATABLE :: ibuf_send(:)
  INTEGER, ALLOCATABLE :: ibuf_receive(:)
  INTEGER ALLOC_ERR

  IF (ht_use_e_emission_from_cathode.OR.ht_use_e_emission_from_cathode_zerogradf.OR.ht_emission_constant) RETURN   ! either PERFORM_ELECTRON_EMISSION_HT_SETUP or PERFORM_ELECTRON_EMISSION_HT_SETUP_ZERO_GRAD_F will be called instead

  IF (c_N_of_local_object_parts.LE.0) RETURN

! in a cluster, all processes have same copy of c_local_object_part (except c_local_object_part%segment_number) and c_index_of_local_object_part_*
! all processes have same copy of whole_object
! therefore each process in a cluster can calculate the number of particles to inject due to constant emission from bondary objects itself
! that is without additional communications with the master

! boundary objects along the left edge of the cluster
  DO n = 1, c_N_of_local_object_parts_left
     m = c_index_of_local_object_part_left(n)
     add_N_e_to_emit = 0.0_8
     nwo = c_local_object_part(m)%object_number
     IF (whole_object(nwo)%N_electron_constant_emit.LE.0.0) CYCLE
     IF (c_left_top_corner_type.EQ.FLAT_WALL_LEFT) THEN
! account for overlapping
        add_N_e_to_emit = DBLE( whole_object(nwo)%N_electron_constant_emit * REAL(MIN(c_local_object_part(m)%jend, c_indx_y_max-1) - c_local_object_part(m)%jstart ) / REAL(whole_object(nwo)%L) )
     ELSE
        add_N_e_to_emit = DBLE( whole_object(nwo)%N_electron_constant_emit * REAL(c_local_object_part(m)%jend - c_local_object_part(m)%jstart ) / REAL(whole_object(nwo)%L) )
     END IF

! account for emission split between multiple processes
     add_N_e_to_emit = add_N_e_to_emit / N_processes_cluster

! integer part of emission
     DO k = 1, INT(add_N_e_to_emit)
        IF (c_left_top_corner_type.EQ.FLAT_WALL_LEFT) THEN 
           y = DBLE(c_local_object_part(m)%jstart) + well_random_number() * DBLE( MIN(c_local_object_part(m)%jend, c_indx_y_max-1) - c_local_object_part(m)%jstart )
           y = MIN(MAX(y, DBLE(c_indx_y_min)), DBLE(c_indx_y_max-1))
        ELSE
! cluster which has no overlapping from above at the top left corner
           y = DBLE(c_local_object_part(m)%jstart) + well_random_number() * DBLE( c_local_object_part(m)%jend - c_local_object_part(m)%jstart )
           y = MIN(MAX(y, DBLE(c_indx_y_min)), DBLE(c_indx_y_max))
        END IF
        x = DBLE(c_indx_x_min) + 1.0d-6   !???

        IF (whole_object(nwo)%model_constant_emit.EQ.0) THEN
! thermal emission
           CALL GetInjMaxwellVelocity(vx)
           vx = vx * whole_object(nwo)%factor_convert_vinj_normal_constant_emit
        ELSE
! warm beam
           CALL GetMaxwellVelocity(vx)
           vx = MAX(0.0_8, whole_object(nwo)%v_ebeam_constant_emit + vx * whole_object(nwo)%factor_convert_vinj_normal_constant_emit)
        END IF
        CALL GetMaxwellVelocity(vy)
        CALL GetMaxwellVelocity(vz)
        vy = vy * whole_object(nwo)%factor_convert_vinj_parallel_constant_emit
        vz = vz * whole_object(nwo)%factor_convert_vinj_parallel_constant_emit
        tag = nwo !0

        CALL ADD_ELECTRON_TO_ADD_LIST(x, y, vx, vy, vz, tag)
        whole_object(nwo)%electron_emit_count = whole_object(nwo)%electron_emit_count + 1
     END DO

! fractional (probabilistic) part of emission
     add_N_e_to_emit = add_N_e_to_emit - INT(add_N_e_to_emit)
     IF (well_random_number().LT.add_N_e_to_emit) THEN
! perform emission
        IF (c_left_top_corner_type.EQ.FLAT_WALL_LEFT) THEN 
           y = DBLE(c_local_object_part(m)%jstart) + well_random_number() * DBLE( MIN(c_local_object_part(m)%jend, c_indx_y_max-1) - c_local_object_part(m)%jstart )
           y = MIN(MAX(y, DBLE(c_indx_y_min)), DBLE(c_indx_y_max-1))
        ELSE
! cluster which has no overlapping from above at the top left corner
           y = DBLE(c_local_object_part(m)%jstart) + well_random_number() * DBLE( c_local_object_part(m)%jend - c_local_object_part(m)%jstart )
           y = MIN(MAX(y, DBLE(c_indx_y_min)), DBLE(c_indx_y_max))
        END IF
        x = DBLE(c_indx_x_min) + 1.0d-6   !???

        IF (whole_object(nwo)%model_constant_emit.EQ.0) THEN
! thermal emission
           CALL GetInjMaxwellVelocity(vx)
           vx = vx * whole_object(nwo)%factor_convert_vinj_normal_constant_emit
        ELSE
! warm beam
           CALL GetMaxwellVelocity(vx)
           vx = MAX(0.0_8, whole_object(nwo)%v_ebeam_constant_emit + vx * whole_object(nwo)%factor_convert_vinj_normal_constant_emit)
        END IF
        CALL GetMaxwellVelocity(vy)
        CALL GetMaxwellVelocity(vz)
        vy = vy * whole_object(nwo)%factor_convert_vinj_parallel_constant_emit
        vz = vz * whole_object(nwo)%factor_convert_vinj_parallel_constant_emit
        tag = nwo !0

        CALL ADD_ELECTRON_TO_ADD_LIST(x, y, vx, vy, vz, tag)
        whole_object(nwo)%electron_emit_count = whole_object(nwo)%electron_emit_count + 1
     END IF

  END DO   !### DO n = 1, c_N_of_local_object_parts_left

! boundary objects along the top edge of the cluster
  DO n = 1, c_N_of_local_object_parts_above
     m = c_index_of_local_object_part_above(n)
     add_N_e_to_emit = 0.0_8
     nwo = c_local_object_part(m)%object_number
     IF (whole_object(nwo)%N_electron_constant_emit.LE.0.0) CYCLE
     IF (c_right_top_corner_type.EQ.FLAT_WALL_ABOVE) THEN
! account for overlapping
        add_N_e_to_emit = DBLE( whole_object(nwo)%N_electron_constant_emit * REAL(MIN(c_local_object_part(m)%iend, c_indx_x_max-1) - c_local_object_part(m)%istart ) / REAL(whole_object(nwo)%L) )
     ELSE
        add_N_e_to_emit = DBLE( whole_object(nwo)%N_electron_constant_emit * REAL(c_local_object_part(m)%iend - c_local_object_part(m)%istart) / REAL(whole_object(nwo)%L) )
     END IF

! account for emission split between multiple processes
     add_N_e_to_emit = add_N_e_to_emit / N_processes_cluster

! integer part of emission
     DO k = 1, INT(add_N_e_to_emit)
        IF (c_right_top_corner_type.EQ.FLAT_WALL_ABOVE) THEN  !Rank_of_master_right.GE.0) THEN
           x = DBLE(c_local_object_part(m)%istart) + well_random_number() * DBLE( MIN(c_local_object_part(m)%iend, c_indx_x_max-1) - c_local_object_part(m)%istart )
           x = MIN(MAX(x, DBLE(c_indx_x_min)), DBLE(c_indx_x_max-1))
        ELSE
! cluster which has no overlapping from right at the top right corner
           x = DBLE(c_local_object_part(m)%istart) + well_random_number() * DBLE( MIN(c_local_object_part(m)%iend, c_indx_x_max) - c_local_object_part(m)%istart )
           x = MIN(MAX(x, DBLE(c_indx_x_min)), DBLE(c_indx_x_max))
        END IF
        y = DBLE(c_indx_y_max) - 1.0d-6   !???

        IF (whole_object(nwo)%model_constant_emit.EQ.0) THEN
! thermal emission
           CALL GetInjMaxwellVelocity(vy)
           vy = -vy * whole_object(nwo)%factor_convert_vinj_normal_constant_emit
        ELSE
! warm beam
           CALL GetMaxwellVelocity(vy)
           vy = -MAX(0.0_8, whole_object(nwo)%v_ebeam_constant_emit + vy * whole_object(nwo)%factor_convert_vinj_normal_constant_emit)
        END IF
        CALL GetMaxwellVelocity(vx)
        CALL GetMaxwellVelocity(vz)
        vx = vx * whole_object(nwo)%factor_convert_vinj_parallel_constant_emit
        vz = vz * whole_object(nwo)%factor_convert_vinj_parallel_constant_emit
        tag = nwo !0

        CALL ADD_ELECTRON_TO_ADD_LIST(x, y, vx, vy, vz, tag)
        whole_object(nwo)%electron_emit_count = whole_object(nwo)%electron_emit_count + 1
     END DO

! fractional (probabilistic) part of emission
     add_N_e_to_emit = add_N_e_to_emit - INT(add_N_e_to_emit)
     IF (well_random_number().LT.add_N_e_to_emit) THEN
! perform emission
        IF (c_right_top_corner_type.EQ.FLAT_WALL_ABOVE) THEN  !Rank_of_master_right.GE.0) THEN
           x = DBLE(c_local_object_part(m)%istart) + well_random_number() * DBLE( MIN(c_local_object_part(m)%iend, c_indx_x_max-1) - c_local_object_part(m)%istart )
           x = MIN(MAX(x, DBLE(c_indx_x_min)), DBLE(c_indx_x_max-1))
        ELSE
! cluster which has no overlapping from right at the top right corner
           x = DBLE(c_local_object_part(m)%istart) + well_random_number() * DBLE( MIN(c_local_object_part(m)%iend, c_indx_x_max) - c_local_object_part(m)%istart )
           x = MIN(MAX(x, DBLE(c_indx_x_min)), DBLE(c_indx_x_max))
        END IF
        y = DBLE(c_indx_y_max) - 1.0d-6   !???

        IF (whole_object(nwo)%model_constant_emit.EQ.0) THEN
! thermal emission
           CALL GetInjMaxwellVelocity(vy)
           vy = -vy * whole_object(nwo)%factor_convert_vinj_normal_constant_emit
        ELSE
! warm beam
           CALL GetMaxwellVelocity(vy)
           vy = -MAX(0.0_8, whole_object(nwo)%v_ebeam_constant_emit + vy * whole_object(nwo)%factor_convert_vinj_normal_constant_emit)
        END IF
        CALL GetMaxwellVelocity(vx)
        CALL GetMaxwellVelocity(vz)
        vx = vx * whole_object(nwo)%factor_convert_vinj_parallel_constant_emit
        vz = vz * whole_object(nwo)%factor_convert_vinj_parallel_constant_emit
        tag = nwo !0

        CALL ADD_ELECTRON_TO_ADD_LIST(x, y, vx, vy, vz, tag)
        whole_object(nwo)%electron_emit_count = whole_object(nwo)%electron_emit_count + 1
     END IF

  END DO   !###   DO n = 1, c_N_of_local_object_parts_above

! boundary objects along the right edge of the cluster
  DO n = 1, c_N_of_local_object_parts_right
     m = c_index_of_local_object_part_right(n)
     add_N_e_to_emit = 0.0_8
     nwo = c_local_object_part(m)%object_number
     IF (whole_object(nwo)%N_electron_constant_emit.LE.0.0) CYCLE
     IF (c_right_top_corner_type.EQ.FLAT_WALL_RIGHT) THEN
! account for overlapping
        add_N_e_to_emit = DBLE( whole_object(nwo)%N_electron_constant_emit * REAL(MIN(c_local_object_part(m)%jend, c_indx_y_max-1) - c_local_object_part(m)%jstart ) / REAL(whole_object(nwo)%L) )
     ELSE
        add_N_e_to_emit = DBLE( whole_object(nwo)%N_electron_constant_emit * REAL(c_local_object_part(m)%jend - c_local_object_part(m)%jstart ) / REAL(whole_object(nwo)%L) )
     END IF

! account for emission split between multiple processes
     add_N_e_to_emit = add_N_e_to_emit / N_processes_cluster

! integer part of emission
     DO k = 1, INT(add_N_e_to_emit)
        IF (c_right_top_corner_type.EQ.FLAT_WALL_RIGHT) THEN 
           y = DBLE(c_local_object_part(m)%jstart) + well_random_number() * DBLE( MIN(c_local_object_part(m)%jend, c_indx_y_max-1) - c_local_object_part(m)%jstart )
           y = MIN(MAX(y, DBLE(c_indx_y_min)), DBLE(c_indx_y_max-1))
        ELSE
! cluster which has no overlapping from above at the top left corner
           y = DBLE(c_local_object_part(m)%jstart) + well_random_number() * DBLE( c_local_object_part(m)%jend - c_local_object_part(m)%jstart )
           y = MIN(MAX(y, DBLE(c_indx_y_min)), DBLE(c_indx_y_max))
        END IF
        x = DBLE(c_indx_x_max) - 1.0d-6   !???

        IF (whole_object(nwo)%model_constant_emit.EQ.0) THEN
! thermal emission
           CALL GetInjMaxwellVelocity(vx)
           vx = -vx * whole_object(nwo)%factor_convert_vinj_normal_constant_emit
        ELSE
! warm beam
           CALL GetMaxwellVelocity(vx)
           vx = -MAX(0.0_8, whole_object(nwo)%v_ebeam_constant_emit + vx * whole_object(nwo)%factor_convert_vinj_normal_constant_emit)
        END IF
        CALL GetMaxwellVelocity(vy)
        CALL GetMaxwellVelocity(vz)
        vy = vy * whole_object(nwo)%factor_convert_vinj_parallel_constant_emit
        vz = vz * whole_object(nwo)%factor_convert_vinj_parallel_constant_emit
        tag = nwo !0

        CALL ADD_ELECTRON_TO_ADD_LIST(x, y, vx, vy, vz, tag)
        whole_object(nwo)%electron_emit_count = whole_object(nwo)%electron_emit_count + 1
     END DO

! fractional (probabilistic) part of emission
     add_N_e_to_emit = add_N_e_to_emit - INT(add_N_e_to_emit)
     IF (well_random_number().LT.add_N_e_to_emit) THEN
! perform emission
        IF (c_right_top_corner_type.EQ.FLAT_WALL_RIGHT) THEN 
           y = DBLE(c_local_object_part(m)%jstart) + well_random_number() * DBLE( MIN(c_local_object_part(m)%jend, c_indx_y_max-1) - c_local_object_part(m)%jstart )
           y = MIN(MAX(y, DBLE(c_indx_y_min)), DBLE(c_indx_y_max-1))
        ELSE
! cluster which has no overlapping from above at the top left corner
           y = DBLE(c_local_object_part(m)%jstart) + well_random_number() * DBLE( c_local_object_part(m)%jend - c_local_object_part(m)%jstart )
           y = MIN(MAX(y, DBLE(c_indx_y_min)), DBLE(c_indx_y_max))
        END IF
        x = DBLE(c_indx_x_max) - 1.0d-6   !???

        IF (whole_object(nwo)%model_constant_emit.EQ.0) THEN
! thermal emission
           CALL GetInjMaxwellVelocity(vx)
           vx = -vx * whole_object(nwo)%factor_convert_vinj_normal_constant_emit
        ELSE
! warm beam
           CALL GetMaxwellVelocity(vx)
           vx = -MAX(0.0_8, whole_object(nwo)%v_ebeam_constant_emit + vx * whole_object(nwo)%factor_convert_vinj_normal_constant_emit)
        END IF
        CALL GetMaxwellVelocity(vy)
        CALL GetMaxwellVelocity(vz)
        vy = vy * whole_object(nwo)%factor_convert_vinj_parallel_constant_emit
        vz = vz * whole_object(nwo)%factor_convert_vinj_parallel_constant_emit
        tag = nwo !0

        CALL ADD_ELECTRON_TO_ADD_LIST(x, y, vx, vy, vz, tag)
        whole_object(nwo)%electron_emit_count = whole_object(nwo)%electron_emit_count + 1
     END IF

  END DO   !###  DO n = 1, c_N_of_local_object_parts_right

! boundary objects along the bottom edge of the cluster
  DO n = 1, c_N_of_local_object_parts_below
     m = c_index_of_local_object_part_below(n)
     add_N_e_to_emit = 0.0_8
     nwo = c_local_object_part(m)%object_number
     IF (whole_object(nwo)%N_electron_constant_emit.LE.0.0) CYCLE
     IF (c_right_bottom_corner_type.EQ.FLAT_WALL_BELOW) THEN
! account for overlapping
        add_N_e_to_emit = DBLE( whole_object(nwo)%N_electron_constant_emit * REAL(MIN(c_local_object_part(m)%iend, c_indx_x_max-1) - c_local_object_part(m)%istart ) / REAL(whole_object(nwo)%L) )
     ELSE
        add_N_e_to_emit = DBLE( whole_object(nwo)%N_electron_constant_emit * REAL(c_local_object_part(m)%iend - c_local_object_part(m)%istart ) / REAL(whole_object(nwo)%L) )
     END IF

! account for emission split between multiple processes
     add_N_e_to_emit = add_N_e_to_emit / N_processes_cluster

! emission
     DO k = 1, INT(add_N_e_to_emit)
        IF (c_right_bottom_corner_type.EQ.FLAT_WALL_BELOW) THEN 
           x = DBLE(c_local_object_part(m)%istart) + well_random_number() * DBLE( MIN(c_local_object_part(m)%iend, c_indx_x_max-1) - c_local_object_part(m)%istart )
           x = MIN(MAX(x, DBLE(c_indx_x_min)), DBLE(c_indx_x_max-1))
        ELSE
! cluster which has no overlapping from right at the top right corner
           x = DBLE(c_local_object_part(m)%istart) + well_random_number() * DBLE( c_local_object_part(m)%iend - c_local_object_part(m)%istart )
           x = MIN(MAX(x, DBLE(c_indx_x_min)), DBLE(c_indx_x_max))
        END IF
        y = DBLE(c_indx_y_min) + 1.0d-6   !???

        IF (whole_object(nwo)%model_constant_emit.EQ.0) THEN
! thermal emission
           CALL GetInjMaxwellVelocity(vy)
           vy = vy * whole_object(nwo)%factor_convert_vinj_normal_constant_emit
        ELSE
! warm beam
           CALL GetMaxwellVelocity(vy)
           vy = MAX(0.0_8, whole_object(nwo)%v_ebeam_constant_emit + vy * whole_object(nwo)%factor_convert_vinj_normal_constant_emit)
        END IF
        CALL GetMaxwellVelocity(vx)
        CALL GetMaxwellVelocity(vz)
        vx = vx * whole_object(nwo)%factor_convert_vinj_parallel_constant_emit
        vz = vz * whole_object(nwo)%factor_convert_vinj_parallel_constant_emit
        tag = nwo !0

        CALL ADD_ELECTRON_TO_ADD_LIST(x, y, vx, vy, vz, tag)
        whole_object(nwo)%electron_emit_count = whole_object(nwo)%electron_emit_count + 1
     END DO

! fractional (probabilistic) part of emission
     add_N_e_to_emit = add_N_e_to_emit - INT(add_N_e_to_emit)
     IF (well_random_number().LT.add_N_e_to_emit) THEN
! perform emission
        IF (c_right_bottom_corner_type.EQ.FLAT_WALL_BELOW) THEN 
           x = DBLE(c_local_object_part(m)%istart) + well_random_number() * DBLE( MIN(c_local_object_part(m)%iend, c_indx_x_max-1) - c_local_object_part(m)%istart )
           x = MIN(MAX(x, DBLE(c_indx_x_min)), DBLE(c_indx_x_max-1))
        ELSE
! cluster which has no overlapping from right at the top right corner
           x = DBLE(c_local_object_part(m)%istart) + well_random_number() * DBLE( c_local_object_part(m)%iend - c_local_object_part(m)%istart )
           x = MIN(MAX(x, DBLE(c_indx_x_min)), DBLE(c_indx_x_max))
        END IF
        y = DBLE(c_indx_y_min) + 1.0d-6   !???

        IF (whole_object(nwo)%model_constant_emit.EQ.0) THEN
! thermal emission
           CALL GetInjMaxwellVelocity(vy)
           vy = vy * whole_object(nwo)%factor_convert_vinj_normal_constant_emit
        ELSE
! warm beam
           CALL GetMaxwellVelocity(vy)
           vy = MAX(0.0_8, whole_object(nwo)%v_ebeam_constant_emit + vy * whole_object(nwo)%factor_convert_vinj_normal_constant_emit)
        END IF
        CALL GetMaxwellVelocity(vx)
        CALL GetMaxwellVelocity(vz)
        vx = vx * whole_object(nwo)%factor_convert_vinj_parallel_constant_emit
        vz = vz * whole_object(nwo)%factor_convert_vinj_parallel_constant_emit
        tag = nwo !0

        CALL ADD_ELECTRON_TO_ADD_LIST(x, y, vx, vy, vz, tag)
        whole_object(nwo)%electron_emit_count = whole_object(nwo)%electron_emit_count + 1
     END IF

  END DO   !###   DO n = 1, c_N_of_local_object_parts_below

! save number of emitted particles, similar to COLLECT_ELECTRON_BOUNDARY_HITS  ???? make it a separate routine???

  ALLOCATE(ibuf_send(1:N_of_boundary_objects), STAT = ALLOC_ERR)
  ALLOCATE(ibuf_receive(1:N_of_boundary_objects), STAT = ALLOC_ERR)

! each cluster adjacent to a boundary assembles electron-boundary hit counters from all cluster members in the master of the cluster

  ibuf_send(1:N_of_boundary_objects) = whole_object(1:N_of_boundary_objects)%electron_emit_count
  ibuf_receive = 0

  CALL MPI_REDUCE(ibuf_send, ibuf_receive, N_of_boundary_objects, MPI_INTEGER, MPI_SUM, 0, COMM_CLUSTER, ierr)

  IF ((cluster_rank_key.EQ.0).AND.(c_N_of_local_object_parts.GT.0)) THEN

     whole_object(1:N_of_boundary_objects)%electron_emit_count = ibuf_receive(1:N_of_boundary_objects)

     ibuf_send(1:N_of_boundary_objects) = whole_object(1:N_of_boundary_objects)%electron_emit_count
     ibuf_receive = 0
! 
     CALL MPI_REDUCE(ibuf_send, ibuf_receive, N_of_boundary_objects, MPI_INTEGER, MPI_SUM, 0, COMM_BOUNDARY, ierr)

     IF (Rank_of_process.EQ.0) THEN
        whole_object(1:N_of_boundary_objects)%electron_emit_count = ibuf_receive(1:N_of_boundary_objects)

print '("electrons emitted by boundaries :: ",10(2x,i8))', whole_object(1:N_of_boundary_objects)%electron_emit_count  

!! set the ion hit counters here to zero because when this subroutine is called the ions do not move
!           DO k = 1, N_of_boundary_objects
!              whole_object(k)%ion_hit_count(1:N_spec) = 0
!           END DO

     END IF
  END IF

  DEALLOCATE(ibuf_send, STAT = ALLOC_ERR)
  DEALLOCATE(ibuf_receive, STAT = ALLOC_ERR)

!print '("process ",i4," of cluster ",i4," emitted ",i5," electrons from top boundary")', Rank_of_process, particle_master, add_N_e_to_emit

END SUBROUTINE PERFORM_ELECTRON_EMISSION_SETUP

!--------------------------------------------
!
SUBROUTINE PERFORM_ELECTRON_EMISSION_SETUP_INNER_OBJECTS

  USE ParallelOperationValues
  USE CurrentProblemValues
  USE ClusterAndItsBoundaries
  USE SetupValues

  USE rng_wrapper

  IMPLICIT NONE

  INCLUDE 'mpif.h'

  INTEGER ierr

  INTEGER nio
  INTEGER cross_j_min, cross_j_max
  INTEGER cross_i_min, cross_i_max

  INTEGER count_open, jj, ii
  REAL(8) dy, dx
  LOGICAL value_assigned

  REAL(8) add_N_e_to_emit

  INTEGER k
  REAL(8) x, y, vx, vy, vz
  INTEGER tag

  INTEGER, ALLOCATABLE :: ibuf_send(:)
  INTEGER, ALLOCATABLE :: ibuf_receive(:)
  INTEGER ALLOC_ERR

  IF (N_of_inner_objects.EQ.0) RETURN

  DO nio = N_of_boundary_objects+1, N_of_boundary_and_inner_objects

     IF (whole_object(nio)%object_type.NE.METAL_WALL) CYCLE

     IF (whole_object(nio)%N_electron_constant_emit.LE.0.0) CYCLE

     IF (whole_object(nio)%ileft.GE.c_indx_x_max) CYCLE
     IF (whole_object(nio)%iright.LE.c_indx_x_min) CYCLE
     IF (whole_object(nio)%jbottom.GE.c_indx_y_max) CYCLE
     IF (whole_object(nio)%jtop.LE.c_indx_y_min) CYCLE

! emission from left side of an inner object (segment #1) -------------------------------------------------------------------------------------------------------------

     IF ((whole_object(nio)%ileft.GT.c_indx_x_min).AND.(whole_object(nio)%ileft.LT.c_indx_x_max)) THEN
        IF ((whole_object(nio)%jbottom.LT.c_indx_y_max).AND.(whole_object(nio)%jtop.GT.c_indx_y_min)) THEN
           cross_j_min = MAX(whole_object(nio)%jbottom, c_indx_y_min)
           cross_j_max = MIN(whole_object(nio)%jtop, c_indx_y_max-1)

! count cells which are not covered and are inside this cluster
           count_open = 0
           DO jj = cross_j_min, cross_j_max-1
              IF (whole_object(nio)%segment(1)%cell_is_covered(jj)) CYCLE 
              count_open = count_open + 1
           END DO

!           add_N_e_to_emit = (whole_object(nio)%N_electron_constant_emit * DBLE(cross_j_max - cross_j_min) / DBLE(whole_object(nio)%L)) / N_processes_cluster
           add_N_e_to_emit = DBLE(whole_object(nio)%N_electron_constant_emit * REAL(count_open) / REAL(whole_object(nio)%L)) / N_processes_cluster

!if ((nio.eq.7).and.(add_N_e_to_emit.gt.0.0)) then
!   print '("proc ",i4," add ",f10.6,2x,"where",2x,i4,2x,i4,2x,i4,2x,i2)', Rank_of_process, add_N_e_to_emit, whole_object(nio)%N_electron_constant_emit, count_open, whole_object(nio)%L, N_processes_cluster
!end if

! integer part of emission
           DO k = 1, INT(add_N_e_to_emit)

              x = whole_object(nio)%Xmin - 1.0d-6   !???

              dy = well_random_number() * (DBLE(count_open) - 1.0d-6)

              value_assigned = .FALSE.
              DO jj = cross_j_min, cross_j_max-1
                 IF (whole_object(nio)%segment(1)%cell_is_covered(jj)) CYCLE
                 IF (dy.LT.1.0_8) THEN
                    y = MAX(DBLE(jj), MIN(DBLE(jj) + dy, DBLE(jj+1)))
                    value_assigned = .TRUE.
                    EXIT
                 END IF
                 dy = dy - 1.0_8
              END DO

! fool proof-1
              IF (.NOT.value_assigned) THEN
                 PRINT '("Error-1 in PERFORM_ELECTRON_EMISSION_SETUP_INNER_OBJECTS")'
                 STOP 
              END IF

!              y = DBLE(cross_j_min) + well_random_number() * DBLE(cross_j_max - cross_j_min)
              y = MIN(MAX(y, DBLE(cross_j_min)), DBLE(cross_j_max)-1.0d-6)

! fool proof-2
              IF (whole_object(nio)%segment(1)%cell_is_covered(jj)) THEN
                 PRINT '("Error-2 in PERFORM_ELECTRON_EMISSION_SETUP_INNER_OBJECTS")'
                 STOP
              END IF

              IF (whole_object(nio)%model_constant_emit.EQ.0) THEN
! thermal emission
                 CALL GetInjMaxwellVelocity(vx)
                 vx = -vx * whole_object(nio)%factor_convert_vinj_normal_constant_emit
              ELSE
! warm beam
                 CALL GetMaxwellVelocity(vx)
                 vx = -MAX(0.0_8, whole_object(nio)%v_ebeam_constant_emit + vx * whole_object(nio)%factor_convert_vinj_normal_constant_emit)
              END IF
              CALL GetMaxwellVelocity(vy)
              CALL GetMaxwellVelocity(vz)
              vy = vy * whole_object(nio)%factor_convert_vinj_parallel_constant_emit
              vz = vz * whole_object(nio)%factor_convert_vinj_parallel_constant_emit
              tag = nio !0

              CALL ADD_ELECTRON_TO_ADD_LIST(x, y, vx, vy, vz, tag)

           END DO

           whole_object(nio)%electron_emit_count = whole_object(nio)%electron_emit_count + INT(add_N_e_to_emit)

! fractional (probabilistic) part of emission
           add_N_e_to_emit = add_N_e_to_emit - INT(add_N_e_to_emit)
           IF (well_random_number().LT.add_N_e_to_emit) THEN
! perform emission

              x = whole_object(nio)%Xmin - 1.0d-6   !???

              dy = well_random_number() * (DBLE(count_open) - 1.0d-6)

              value_assigned = .FALSE.
              DO jj = cross_j_min, cross_j_max-1
                 IF (whole_object(nio)%segment(1)%cell_is_covered(jj)) CYCLE
                 IF (dy.LT.1.0_8) THEN
                    y = MAX(DBLE(jj), MIN(DBLE(jj) + dy, DBLE(jj+1)))
                    value_assigned = .TRUE.
                    EXIT
                 END IF
                 dy = dy - 1.0_8
              END DO

! fool proof-1
              IF (.NOT.value_assigned) THEN
                 PRINT '("Error-3 in PERFORM_ELECTRON_EMISSION_SETUP_INNER_OBJECTS")'
                 STOP 
              END IF

!              y = DBLE(cross_j_min) + well_random_number() * DBLE(cross_j_max - cross_j_min)
              y = MIN(MAX(y, DBLE(cross_j_min)), DBLE(cross_j_max)-1.0d-6)

! fool proof-2
              IF (whole_object(nio)%segment(1)%cell_is_covered(jj)) THEN
                 PRINT '("Error-4 in PERFORM_ELECTRON_EMISSION_SETUP_INNER_OBJECTS")'
                 STOP
              END IF

              IF (whole_object(nio)%model_constant_emit.EQ.0) THEN
! thermal emission
                 CALL GetInjMaxwellVelocity(vx)
                 vx = -vx * whole_object(nio)%factor_convert_vinj_normal_constant_emit
              ELSE
! warm beam
                 CALL GetMaxwellVelocity(vx)
                 vx = -MAX(0.0_8, whole_object(nio)%v_ebeam_constant_emit + vx * whole_object(nio)%factor_convert_vinj_normal_constant_emit)
              END IF
              CALL GetMaxwellVelocity(vy)
              CALL GetMaxwellVelocity(vz)
              vy = vy * whole_object(nio)%factor_convert_vinj_parallel_constant_emit
              vz = vz * whole_object(nio)%factor_convert_vinj_parallel_constant_emit
              tag = nio !0

              CALL ADD_ELECTRON_TO_ADD_LIST(x, y, vx, vy, vz, tag)

              whole_object(nio)%electron_emit_count = whole_object(nio)%electron_emit_count + 1
           END IF

        END IF !###  IF ((whole_object(nio)%jbottom.LT.c_indx_y_max).AND.(whole_object(nio)%jtop.GT.c_indx_y_min)) THEN
     END IF    !###  IF ((whole_object(nio)%ileft.GT.c_indx_x_min).AND.(whole_object(nio)%ileft.LT.c_indx_x_max)) THEN

! emission from right side of an inner object (segment #3) -------------------------------------------------------------------------------------------------------------

     IF ((whole_object(nio)%iright.GT.c_indx_x_min).AND.(whole_object(nio)%iright.LT.c_indx_x_max)) THEN
        IF ((whole_object(nio)%jbottom.LT.c_indx_y_max).AND.(whole_object(nio)%jtop.GT.c_indx_y_min)) THEN
           cross_j_min = MAX(whole_object(nio)%jbottom, c_indx_y_min)
           cross_j_max = MIN(whole_object(nio)%jtop, c_indx_y_max-1)

! count cells which are not covered and are inside this cluster
           count_open = 0
           DO jj = cross_j_min, cross_j_max-1
              IF (whole_object(nio)%segment(3)%cell_is_covered(jj)) CYCLE 
              count_open = count_open + 1
           END DO

!           add_N_e_to_emit = (whole_object(nio)%N_electron_constant_emit * DBLE(cross_j_max - cross_j_min) / DBLE(whole_object(nio)%L)) / N_processes_cluster
           add_N_e_to_emit = DBLE(whole_object(nio)%N_electron_constant_emit * REAL(count_open) / REAL(whole_object(nio)%L)) / N_processes_cluster

! integer part of emission
           DO k = 1, INT(add_N_e_to_emit)

              x = whole_object(nio)%Xmax + 1.0d-6   !???

              dy = well_random_number() * (DBLE(count_open) - 1.0d-6)

              value_assigned = .FALSE.
              DO jj = cross_j_min, cross_j_max-1
                 IF (whole_object(nio)%segment(3)%cell_is_covered(jj)) CYCLE
                 IF (dy.LT.1.0_8) THEN
                    y = MAX(DBLE(jj), MIN(DBLE(jj) + dy, DBLE(jj+1)))
                    value_assigned = .TRUE.
                    EXIT
                 END IF
                 dy = dy - 1.0_8
              END DO

! fool proof-1
              IF (.NOT.value_assigned) THEN
                 PRINT '("Error-5 in PERFORM_ELECTRON_EMISSION_SETUP_INNER_OBJECTS")'
                 STOP 
              END IF

!              y = DBLE(cross_j_min) + well_random_number() * DBLE(cross_j_max - cross_j_min)
              y = MIN(MAX(y, DBLE(cross_j_min)), DBLE(cross_j_max)-1.0d-6)
        
! fool proof-2
              IF (whole_object(nio)%segment(3)%cell_is_covered(jj)) THEN
                 PRINT '("Error-6 in PERFORM_ELECTRON_EMISSION_SETUP_INNER_OBJECTS")'
                 STOP
              END IF

              IF (whole_object(nio)%model_constant_emit.EQ.0) THEN
! thermal emission
                 CALL GetInjMaxwellVelocity(vx)
                 vx = vx * whole_object(nio)%factor_convert_vinj_normal_constant_emit
              ELSE
! warm beam
                 CALL GetMaxwellVelocity(vx)
                 vx = MAX(0.0_8, whole_object(nio)%v_ebeam_constant_emit + vx * whole_object(nio)%factor_convert_vinj_normal_constant_emit)
              END IF
              CALL GetMaxwellVelocity(vy)
              CALL GetMaxwellVelocity(vz)
              vy = vy * whole_object(nio)%factor_convert_vinj_parallel_constant_emit
              vz = vz * whole_object(nio)%factor_convert_vinj_parallel_constant_emit
              tag = nio !0

              CALL ADD_ELECTRON_TO_ADD_LIST(x, y, vx, vy, vz, tag)

           END DO

           whole_object(nio)%electron_emit_count = whole_object(nio)%electron_emit_count + INT(add_N_e_to_emit)

! fractional (probabilistic) part of emission
           add_N_e_to_emit = add_N_e_to_emit - INT(add_N_e_to_emit)
           IF (well_random_number().LT.add_N_e_to_emit) THEN
! perform emission

              x = whole_object(nio)%Xmax + 1.0d-6   !???

              dy = well_random_number() * (DBLE(count_open) - 1.0d-6)

              value_assigned = .FALSE.
              DO jj = cross_j_min, cross_j_max-1
                 IF (whole_object(nio)%segment(3)%cell_is_covered(jj)) CYCLE
                 IF (dy.LT.1.0_8) THEN
                    y = MAX(DBLE(jj), MIN(DBLE(jj) + dy, DBLE(jj+1)))
                    value_assigned = .TRUE.
                    EXIT
                 END IF
                 dy = dy - 1.0_8
              END DO

! fool proof-1
              IF (.NOT.value_assigned) THEN
                 PRINT '("Error-7 in PERFORM_ELECTRON_EMISSION_SETUP_INNER_OBJECTS")'
                 STOP 
              END IF

!              y = DBLE(cross_j_min) + well_random_number() * DBLE(cross_j_max - cross_j_min)
              y = MIN(MAX(y, DBLE(cross_j_min)), DBLE(cross_j_max)-1.0d-6)

! fool proof-2
              IF (whole_object(nio)%segment(3)%cell_is_covered(jj)) THEN
                 PRINT '("Error-8 in PERFORM_ELECTRON_EMISSION_SETUP_INNER_OBJECTS")'
                 STOP
              END IF

              IF (whole_object(nio)%model_constant_emit.EQ.0) THEN
! thermal emission
                 CALL GetInjMaxwellVelocity(vx)
                 vx = vx * whole_object(nio)%factor_convert_vinj_normal_constant_emit
              ELSE
! warm beam
                 CALL GetMaxwellVelocity(vx)
                 vx = MAX(0.0_8, whole_object(nio)%v_ebeam_constant_emit + vx * whole_object(nio)%factor_convert_vinj_normal_constant_emit)
              END IF
              CALL GetMaxwellVelocity(vy)
              CALL GetMaxwellVelocity(vz)
              vy = vy * whole_object(nio)%factor_convert_vinj_parallel_constant_emit
              vz = vz * whole_object(nio)%factor_convert_vinj_parallel_constant_emit
              tag = nio !0

              CALL ADD_ELECTRON_TO_ADD_LIST(x, y, vx, vy, vz, tag)

              whole_object(nio)%electron_emit_count = whole_object(nio)%electron_emit_count + 1
           END IF

        END IF !###  IF ((whole_object(nio)%jbottom.LT.c_indx_y_max).AND.(whole_object(nio)%jtop.GT.c_indx_y_min)) THEN
     END IF    !###  IF ((whole_object(nio)%iright.GT.c_indx_x_min).AND.(whole_object(nio)%iright.LT.c_indx_x_max)) THEN

! emission from bottom side of an inner object (segment #4) -------------------------------------------------------------------------------------------------------------

     IF ((whole_object(nio)%jbottom.GT.c_indx_y_min).AND.(whole_object(nio)%jbottom.LT.c_indx_y_max)) THEN
        IF ((whole_object(nio)%ileft.LT.c_indx_x_max).AND.(whole_object(nio)%iright.GT.c_indx_x_min)) THEN
           cross_i_min = MAX(whole_object(nio)%ileft, c_indx_x_min)
           cross_i_max = MIN(whole_object(nio)%iright, c_indx_x_max-1)

! count cells which are not covered and are inside this cluster
           count_open = 0
           DO ii = cross_i_min, cross_i_max-1
              IF (whole_object(nio)%segment(4)%cell_is_covered(ii)) CYCLE 
              count_open = count_open + 1
           END DO

!           add_N_e_to_emit = (whole_object(nio)%N_electron_constant_emit * DBLE(cross_i_max - cross_i_min) / DBLE(whole_object(nio)%L)) / N_processes_cluster
           add_N_e_to_emit = DBLE(whole_object(nio)%N_electron_constant_emit * REAL(count_open) / REAL(whole_object(nio)%L)) / N_processes_cluster

! integer part of emission
           DO k = 1, INT(add_N_e_to_emit)

              y = whole_object(nio)%Ymin - 1.0d-6   !???

              dx = well_random_number() * (DBLE(count_open) - 1.0d-6)

              value_assigned = .FALSE.
              DO ii = cross_i_min, cross_i_max-1
                 IF (whole_object(nio)%segment(4)%cell_is_covered(ii)) CYCLE
                 IF (dx.LT.1.0_8) THEN
                    x = MAX(DBLE(ii), MIN(DBLE(ii) + dx, DBLE(ii+1)))
                    value_assigned = .TRUE.
                    EXIT
                 END IF
                 dx = dx - 1.0_8
              END DO

! fool proof-1
              IF (.NOT.value_assigned) THEN
                 PRINT '("Error-9 in PERFORM_ELECTRON_EMISSION_SETUP_INNER_OBJECTS")'
                 STOP 
              END IF

!              x = DBLE(cross_i_min) + well_random_number() * DBLE(cross_i_max - cross_i_min)
              x = MIN(MAX(x, DBLE(cross_i_min)), DBLE(cross_i_max)-1.0d-6)

! fool proof-2
              IF (whole_object(nio)%segment(4)%cell_is_covered(ii)) THEN
                 PRINT '("Error-10 in PERFORM_ELECTRON_EMISSION_SETUP_INNER_OBJECTS")'
                 STOP
              END IF

              IF (whole_object(nio)%model_constant_emit.EQ.0) THEN
! thermal emission
                 CALL GetInjMaxwellVelocity(vy)
                 vy = -vy * whole_object(nio)%factor_convert_vinj_normal_constant_emit
              ELSE
! warm beam
                 CALL GetMaxwellVelocity(vy)
                 vy = -MAX(0.0_8, whole_object(nio)%v_ebeam_constant_emit + vy * whole_object(nio)%factor_convert_vinj_normal_constant_emit)
              END IF
              CALL GetMaxwellVelocity(vx)
              CALL GetMaxwellVelocity(vz)
              vx = vx * whole_object(nio)%factor_convert_vinj_parallel_constant_emit
              vz = vz * whole_object(nio)%factor_convert_vinj_parallel_constant_emit
              tag = nio !0

              CALL ADD_ELECTRON_TO_ADD_LIST(x, y, vx, vy, vz, tag)

           END DO

           whole_object(nio)%electron_emit_count = whole_object(nio)%electron_emit_count + INT(add_N_e_to_emit)

! fractional (probabilistic) part of emission
           add_N_e_to_emit = add_N_e_to_emit - INT(add_N_e_to_emit)
           IF (well_random_number().LT.add_N_e_to_emit) THEN
! perform emission

              y = whole_object(nio)%Ymin - 1.0d-6   !???

              dx = well_random_number() * (DBLE(count_open) - 1.0d-6)

              value_assigned = .FALSE.
              DO ii = cross_i_min, cross_i_max-1
                 IF (whole_object(nio)%segment(4)%cell_is_covered(ii)) CYCLE
                 IF (dx.LT.1.0_8) THEN
                    x = MAX(DBLE(ii), MIN(DBLE(ii) + dx, DBLE(ii+1)))
                    value_assigned = .TRUE.
                    EXIT
                 END IF
                 dx = dx - 1.0_8
              END DO

! fool proof-1
              IF (.NOT.value_assigned) THEN
                 PRINT '("Error-11 in PERFORM_ELECTRON_EMISSION_SETUP_INNER_OBJECTS")'
                 STOP 
              END IF

!              x = DBLE(cross_i_min) + well_random_number() * DBLE(cross_i_max - cross_i_min)
              x = MIN(MAX(x, DBLE(cross_i_min)), DBLE(cross_i_max)-1.0d-6)

! fool proof-2
              IF (whole_object(nio)%segment(4)%cell_is_covered(ii)) THEN
                 PRINT '("Error-12 in PERFORM_ELECTRON_EMISSION_SETUP_INNER_OBJECTS")'
                 STOP
              END IF

              IF (whole_object(nio)%model_constant_emit.EQ.0) THEN
! thermal emission
                 CALL GetInjMaxwellVelocity(vy)
                 vy = -vy * whole_object(nio)%factor_convert_vinj_normal_constant_emit
              ELSE
! warm beam
                 CALL GetMaxwellVelocity(vy)
                 vy = -MAX(0.0_8, whole_object(nio)%v_ebeam_constant_emit + vy * whole_object(nio)%factor_convert_vinj_normal_constant_emit)
              END IF
              CALL GetMaxwellVelocity(vx)
              CALL GetMaxwellVelocity(vz)
              vx = vx * whole_object(nio)%factor_convert_vinj_parallel_constant_emit
              vz = vz * whole_object(nio)%factor_convert_vinj_parallel_constant_emit
              tag = nio !0

              CALL ADD_ELECTRON_TO_ADD_LIST(x, y, vx, vy, vz, tag)

              whole_object(nio)%electron_emit_count = whole_object(nio)%electron_emit_count + 1
           END IF

        END IF !###  IF ((whole_object(nio)%ileft.LT.c_indx_x_max).AND.(whole_object(nio)%iright.GT.c_indx_x_min)) THEN
     END IF    !###  IF ((whole_object(nio)%jbottom.GT.c_indx_y_min).AND.(whole_object(nio)%jbottom.LT.c_indx_y_max)) THEN


! emission from top side of an inner object (segment #2) -------------------------------------------------------------------------------------------------------------

     IF ((whole_object(nio)%jtop.GT.c_indx_y_min).AND.(whole_object(nio)%jtop.LT.c_indx_y_max)) THEN
        IF ((whole_object(nio)%ileft.LT.c_indx_x_max).AND.(whole_object(nio)%iright.GT.c_indx_x_min)) THEN
           cross_i_min = MAX(whole_object(nio)%ileft, c_indx_x_min)
           cross_i_max = MIN(whole_object(nio)%iright, c_indx_x_max-1)

! count cells which are not covered and are inside this cluster
           count_open = 0
           DO ii = cross_i_min, cross_i_max-1
              IF (whole_object(nio)%segment(2)%cell_is_covered(ii)) CYCLE 
              count_open = count_open + 1
           END DO

!           add_N_e_to_emit = (whole_object(nio)%N_electron_constant_emit * DBLE(cross_i_max - cross_i_min) / whole_object(nio)%L) / N_processes_cluster
           add_N_e_to_emit = DBLE(whole_object(nio)%N_electron_constant_emit * REAL(count_open) / REAL(whole_object(nio)%L)) / N_processes_cluster

! integer part of emission
           DO k = 1, INT(add_N_e_to_emit)

              y = whole_object(nio)%Ymax + 1.0d-6   !???

              dx = well_random_number() * (DBLE(count_open) - 1.0d-6)

              value_assigned = .FALSE.
              DO ii = cross_i_min, cross_i_max-1
                 IF (whole_object(nio)%segment(2)%cell_is_covered(ii)) CYCLE
                 IF (dx.LT.1.0_8) THEN
                    x = MAX(DBLE(ii), MIN(DBLE(ii) + dx, DBLE(ii+1)))
                    value_assigned = .TRUE.
                    EXIT
                 END IF
                 dx = dx - 1.0_8
              END DO

! fool proof-1
              IF (.NOT.value_assigned) THEN
                 PRINT '("Error-13 in PERFORM_ELECTRON_EMISSION_SETUP_INNER_OBJECTS")'
                 STOP 
              END IF

!              x = DBLE(cross_i_min) + well_random_number() * DBLE(cross_i_max - cross_i_min)
              x = MIN(MAX(x, DBLE(cross_i_min)), DBLE(cross_i_max)-1.0d-6)

! fool proof-2
              IF (whole_object(nio)%segment(2)%cell_is_covered(ii)) THEN
                 PRINT '("Error-14 in PERFORM_ELECTRON_EMISSION_SETUP_INNER_OBJECTS")'
                 STOP
              END IF

              IF (whole_object(nio)%model_constant_emit.EQ.0) THEN
! thermal emission
                 CALL GetInjMaxwellVelocity(vy)
                 vy = vy * whole_object(nio)%factor_convert_vinj_normal_constant_emit
              ELSE
! warm beam
                 CALL GetMaxwellVelocity(vy)
                 vy = MAX(0.0_8, whole_object(nio)%v_ebeam_constant_emit + vy * whole_object(nio)%factor_convert_vinj_normal_constant_emit)
              END IF
              CALL GetMaxwellVelocity(vx)
              CALL GetMaxwellVelocity(vz)
              vx = vx * whole_object(nio)%factor_convert_vinj_parallel_constant_emit
              vz = vz * whole_object(nio)%factor_convert_vinj_parallel_constant_emit
              tag = nio !0

              CALL ADD_ELECTRON_TO_ADD_LIST(x, y, vx, vy, vz, tag)

           END DO

           whole_object(nio)%electron_emit_count = whole_object(nio)%electron_emit_count + INT(add_N_e_to_emit)

! fractional (probabilistic) part of emission
           add_N_e_to_emit = add_N_e_to_emit - INT(add_N_e_to_emit)
           IF (well_random_number().LT.add_N_e_to_emit) THEN
! perform emission

              y = whole_object(nio)%Ymax + 1.0d-6   !???

              dx = well_random_number() * (DBLE(count_open) - 1.0d-6)

              value_assigned = .FALSE.
              DO ii = cross_i_min, cross_i_max-1
                 IF (whole_object(nio)%segment(2)%cell_is_covered(ii)) CYCLE
                 IF (dx.LT.1.0_8) THEN
                    x = MAX(DBLE(ii), MIN(DBLE(ii) + dx, DBLE(ii+1)))
                    value_assigned = .TRUE.
                    EXIT
                 END IF
                 dx = dx - 1.0_8
              END DO

! fool proof-1
              IF (.NOT.value_assigned) THEN
                 PRINT '("Error-15 in PERFORM_ELECTRON_EMISSION_SETUP_INNER_OBJECTS")'
                 STOP 
              END IF

!              x = DBLE(cross_i_min) + well_random_number() * DBLE(cross_i_max - cross_i_min)
              x = MIN(MAX(x, DBLE(cross_i_min)), DBLE(cross_i_max)-1.0d-6)

! fool proof-2
              IF (whole_object(nio)%segment(2)%cell_is_covered(ii)) THEN
                 PRINT '("Error-16 in PERFORM_ELECTRON_EMISSION_SETUP_INNER_OBJECTS")'
                 STOP
              END IF

              IF (whole_object(nio)%model_constant_emit.EQ.0) THEN
! thermal emission
                 CALL GetInjMaxwellVelocity(vy)
                 vy = vy * whole_object(nio)%factor_convert_vinj_normal_constant_emit
              ELSE
! warm beam
                 CALL GetMaxwellVelocity(vy)
                 vy = MAX(0.0_8, whole_object(nio)%v_ebeam_constant_emit + vy * whole_object(nio)%factor_convert_vinj_normal_constant_emit)
              END IF
              CALL GetMaxwellVelocity(vx)
              CALL GetMaxwellVelocity(vz)
              vx = vx * whole_object(nio)%factor_convert_vinj_parallel_constant_emit
              vz = vz * whole_object(nio)%factor_convert_vinj_parallel_constant_emit
              tag = nio !0

              CALL ADD_ELECTRON_TO_ADD_LIST(x, y, vx, vy, vz, tag)

              whole_object(nio)%electron_emit_count = whole_object(nio)%electron_emit_count + 1
           END IF

        END IF !###  IF ((whole_object(nio)%ileft.LT.c_indx_x_max).AND.(whole_object(nio)%iright.GT.c_indx_x_min)) THEN
     END IF    !###  IF ((whole_object(nio)%jtop.GT.c_indx_y_min).AND.(whole_object(nio)%jtop.LT.c_indx_y_max)) THEN

  END DO   !### DO nio = N_of_boundary_objects+1, N_of_boundary_and_inner_objects

! collect emission counters in process with rank zero

  ALLOCATE(ibuf_send(1:N_of_inner_objects), STAT = ALLOC_ERR)
  ALLOCATE(ibuf_receive(1:N_of_inner_objects), STAT = ALLOC_ERR)

  ibuf_send(1:N_of_inner_objects) = whole_object(N_of_boundary_objects+1:N_of_boundary_and_inner_objects)%electron_emit_count
  ibuf_receive = 0

  CALL MPI_REDUCE(ibuf_send, ibuf_receive, N_of_inner_objects, MPI_INTEGER, MPI_SUM, 0, MPI_COMM_WORLD, ierr)

  IF (Rank_of_process.EQ.0) THEN
     whole_object(N_of_boundary_objects+1:N_of_boundary_and_inner_objects)%electron_emit_count = ibuf_receive(1:N_of_inner_objects)
  END IF

  DEALLOCATE(ibuf_send, STAT = ALLOC_ERR)
  DEALLOCATE(ibuf_receive, STAT = ALLOC_ERR)

END SUBROUTINE PERFORM_ELECTRON_EMISSION_SETUP_INNER_OBJECTS
