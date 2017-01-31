! Solve_master

module solver

  use problem_class, only : problem_type

  implicit none
  private

  integer(kind=8), save :: iktotal

  public  :: solve

contains

!=====================================================================
! Master Solver
!
subroutine solve(pb)

  use output, only : screen_init, screen_write, ox_write, ot_write
  use my_mpi, only: is_MPI_parallel, is_mpi_master, finalize_mpi

  type(problem_type), intent(inout)  :: pb

  if (is_mpi_master()) call screen_init(pb)
  call screen_write(pb)
  call ox_write(pb)

  iktotal=0
  ! Time loop
  do while (pb%it /= pb%itstop)
!  do while (pb%it+1 /= pb%itstop)
    pb%it = pb%it + 1
!   if (is_mpi_master()) write(6,*) 'it:',pb%it
    call do_bsstep(pb)
! if stress exceeds yield call Coulomb_solver ! JPA Coulomb quick and dirty
!                         or (cleaner version) do linear adjustment of
!                         timestep then redo bsstep
!                         or (cleanest version) iterate tiemstep adjustment and
!                         bsstep until stress is exactly equal to yield
    call update_field(pb)
    ! SEISMIC: shouldn't there be a specific output time step for ot_write
    ! as well? I.e. to have something like ntout for screen_write and one
    ! for ot_write
    call ot_write(pb)
    call check_stop(pb)   ! here itstop will change
!--------Output onestep to screen and ox file(snap_shot)
! if(mod(pb%it-1,pb%ot%ntout) == 0 .or. pb%it == pb%itstop) then
    if(mod(pb%it,pb%ot%ntout) == 0 .or. pb%it == pb%itstop) then
!      if (is_mpi_master()) write(6,*) 'it:',pb%it,'iktotal=',iktotal,'pb%time=',pb%time
      call screen_write(pb)
    endif
! if (is_mpi_master()) call ox_write(pb)
    call ox_write(pb)
  enddo

  if (is_MPI_parallel()) call finalize_mpi()

end subroutine solve



!=====================================================================
! pack, do bs_step and unpack
!
! IMPORTANT NOTE : between pack/unpack pb%v & pb%theta are not up-to-date
! SEISMIC IMPORTANT NOTE: when the CNS model is used, pb%tau is not up-to-date
!
subroutine do_bsstep(pb)

  use derivs_all
  use ode_bs

  type(problem_type), intent(inout) :: pb

  double precision, dimension(pb%neqs*pb%mesh%nn) :: yt, dydt, yt_scale
  integer :: ik, ind_stress_coupling, ind_cohesion

  ! Pack v, theta into yt
  ! yt(2::pb%neqs) = pb%v(pb%rs_nodes) ! JPA Coulomb

  ! SEISMIC: define the indices of yt and dydt based on which
  ! features are requested (defined in input file)
  ind_stress_coupling = 2 + pb%features%stress_coupling
  ind_cohesion = ind_stress_coupling + pb%features%cohesion

  ! SEISMIC: in the case of the CNS model, solve for tau and not v
  if (pb%i_rns_law == 3) then   ! SEISMIC: CNS model
    yt(2::pb%neqs) = pb%tau
    dydt(2::pb%neqs) = pb%dtau_dt
  else  ! SEISMIC: not CNS model (i.e. rate-and-state)
    yt(2::pb%neqs) = pb%v
    dydt(2::pb%neqs) = pb%dv_dt
  endif
  yt(1::pb%neqs) = pb%theta
  dydt(1::pb%neqs) = pb%dtheta_dt
  ! SEISMIC NOTE/WARNING: I don't know how permanent this temporary solution is,
  ! but in case it gets fixed more permanently, derivs_all.f90 needs adjustment
  if (pb%features%stress_coupling == 1) then           ! Temp solution for normal stress coupling
    yt(ind_stress_coupling::pb%neqs) = pb%sigma
    dydt(ind_stress_coupling::pb%neqs) = pb%dsigma_dt
  endif
  if (pb%features%cohesion == 1) then
    yt(ind_cohesion::pb%neqs) = pb%alpha
    dydt(ind_cohesion::pb%neqs) = pb%dalpha_dt
  endif

  ! this update of derivatives is only needed to set up the scaling (yt_scale)
  call derivs(pb%time,yt,dydt,pb)
  yt_scale=dabs(yt)+dabs(pb%dt_try*dydt)
  ! One step
  call bsstep(yt,dydt,pb%neqs*pb%mesh%nn,pb%time,pb%dt_try,pb%acc,yt_scale,pb%dt_did,pb%dt_next,pb,ik)
  !PG: Here is necessary a global min, or dt_next and dt_max is the same in all processors?.
  if (pb%dt_max >  0.d0) then
    pb%dt_try = min(pb%dt_next,pb%dt_max)
  else
    pb%dt_try = pb%dt_next
  endif
  iktotal=ik+iktotal
  !  if (MY_RANK==0) write(6,*) 'iktotal=',iktotal,'pb%time=',pb%time
  ! Unpack yt into v, theta
  !  pb%v(pb%rs_nodes) = yt(2::pb%neqs) ! JPA Coulomb

  ! SEISMIC: retrieve the solution for tau in the case of the CNS model, else
  ! retreive the solution for slip velocity
  if (pb%i_rns_law == 3) then
    pb%tau = yt(2::pb%neqs)
    pb%dtau_dt = dydt(2::pb%neqs)
  else
    pb%v = yt(2::pb%neqs)
    pb%dv_dt = dydt(2::pb%neqs)
  endif

  pb%theta = yt(1::pb%neqs)
  pb%dtheta_dt = dydt(1::pb%neqs)
  ! SEISMIC NOTE/WARNING: I don't know how permanent this temporary solution is,
  ! but in case it gets fixed more permanently, derivs_all.f90 needs adjustment
  if (pb%features%stress_coupling == 1) then           ! Temp solution for normal stress coupling
    pb%sigma = yt(ind_stress_coupling::pb%neqs)
    pb%dsigma_dt = dydt(ind_stress_coupling::pb%neqs)
  endif

  if (pb%features%cohesion == 1) then
    pb%alpha = yt(ind_cohesion::pb%neqs)
    pb%dalpha_dt = dydt(ind_cohesion::pb%neqs)
  endif

end subroutine do_bsstep


!=====================================================================
! Update field: slip, tau, potency potency rate, crack,
!
subroutine update_field(pb)

  use output, only : crack_size
  use friction, only : friction_mu, compute_velocity
  use my_mpi, only: max_allproc, is_MPI_parallel

  type(problem_type), intent(inout) :: pb

  integer :: i,ix,iw
  double precision :: vtemp, k

  ! SEISMIC: in case of the CNS model, re-compute the slip velocity with
  ! the final value of tau, sigma, and porosity. Otherwise, use the standard
  ! rate-and-state expression to calculate tau as a function of velocity
  if (pb%i_rns_law == 3) then
    pb%v = compute_velocity(pb%tau, pb%sigma, pb%theta, pb%alpha, pb)
  else
    pb%tau = pb%sigma * friction_mu(pb%v,pb%theta,pb) + pb%coh
  endif
  ! Update slip
  ! SEISMIC NOTE: slip needs to be calculated after velocity!
  pb%slip = pb%slip + pb%v*pb%dt_did

  ! update potency and potency rate
  pb%pot=0d0;
  pb%pot_rate=0d0;
  if (pb%mesh%dim == 0 .or. pb%mesh%dim == 1) then
    pb%pot = sum(pb%slip) * pb%mesh%dx
    pb%pot_rate = sum(pb%v) * pb%mesh%dx
  else
    do iw=1,pb%mesh%nw
      do ix=1,pb%mesh%nx
        i=(iw-1)*pb%mesh%nx+ix
        pb%pot = pb%pot + pb%slip(i) * pb%mesh%dx * pb%mesh%dw(iw)
        pb%pot_rate = pb%pot_rate + pb%v(i) * pb%mesh%dx * pb%mesh%dw(iw)
      end do
    end do
  endif
!PG: the crack size only work in serial.
  ! update crack size
  pb%ot%lcold = pb%ot%lcnew
  pb%ot%lcnew = crack_size(pb%slip,pb%mesh%nn)
  pb%ot%llocold = pb%ot%llocnew
  pb%ot%llocnew = crack_size(pb%dtau_dt,pb%mesh%nn)
  ! Output time series at max(v) location
  vtemp=0d0
  do i=1,pb%mesh%nn
     if ( pb%v(i) > vtemp) then
       vtemp = pb%v(i)
       pb%ot%ivmax = i
     end if
  end do
 if (is_MPI_parallel()) then
! Finding global vmax
   call max_allproc(pb%v(pb%ot%ivmax),pb%vmaxglob)
!   if.not.(vtemp==vtempglob) pb%ot%ivmax=-1 !This processor does not host the maximum vel.
 endif

end subroutine update_field

!=====================================================================
! check stop:
!
subroutine check_stop(pb)

  use output, only : time_write
  use my_mpi, only: is_MPI_parallel

  type(problem_type), intent(inout) :: pb

  double precision, save :: vmax_old = 0d0, vmax_older = 0d0

if (is_MPI_parallel()) then
! In progress
  if (pb%itstop == -1) then
      !         STOP soon after end of slip localization
    if (pb%NSTOP == 1) then
    !  if (pb%ot%llocnew > pb%ot%llocold) pb%itstop=pb%it+2*pb%ot%ntout

      ! STOP soon after maximum slip rate
    elseif (pb%NSTOP == 2) then

    !  if (pb%it > 2 .and. vmax_old > vmax_older .and. pb%v(pb%ot%ivmax) < vmax_old)  &
    !      pb%itstop = pb%it+10*pb%ot%ntout
    !  vmax_older = vmax_old
    !  vmax_old = pb%v(pb%ot%ivmax)

        !         STOP at a slip rate threshold
    elseif (pb%NSTOP == 3) then
      if (pb%vmaxglob > pb%tmax) pb%itstop = pb%it    !here tmax is threshhold velocity
        !         STOP if time > tmax
    else
!      if (MY_RANK==0) call time_write(pb)
      if (pb%tmax > 0.d0 .and. pb%time > pb%tmax) pb%itstop = pb%it
    endif
  endif

else

  if (pb%itstop == -1) then
      !         STOP soon after end of slip localization
    if (pb%NSTOP == 1) then
      if (pb%ot%llocnew > pb%ot%llocold) pb%itstop=pb%it+2*pb%ot%ntout

      ! STOP soon after maximum slip rate
    elseif (pb%NSTOP == 2) then

      if (pb%it > 2 .and. vmax_old > vmax_older .and. pb%v(pb%ot%ivmax) < vmax_old)  &
          pb%itstop = pb%it+10*pb%ot%ntout
      vmax_older = vmax_old
      vmax_old = pb%v(pb%ot%ivmax)

        !         STOP at a slip rate threshold
    elseif (pb%NSTOP == 3) then
      if (pb%v(pb%ot%ivmax) > pb%tmax) pb%itstop = pb%it    !here tmax is threshhold velocity

        !         STOP if time > tmax
    else
      call time_write(pb)
      if (pb%tmax > 0.d0 .and. pb%time > pb%tmax) pb%itstop = pb%it
    endif
  endif

endif

end subroutine check_stop



end module solver
