module macproject_module

  use bl_types
  use define_bc_module
  use multifab_module
  use boxarray_module
  use stencil_module
  use multifab_fill_ghost_module
  use ml_restriction_module
  use flux_reg_module

  implicit none

contains 

subroutine macproject(nlevs,la_tower,umac,rho,dx,the_bc_tower, &
                      verbose,mg_verbose)

  integer       , intent(in   ) :: nlevs
  type(layout)  , intent(inout) :: la_tower(:)
  type(multifab), intent(inout) :: umac(:)
  type(multifab), intent(inout) :: rho(:)
  real(dp_t)    , intent(in   ) :: dx(:,:)
  type(bc_tower), intent(in   ) :: the_bc_tower
  integer       , intent(in   ) :: verbose,mg_verbose

! Local  
  type(multifab), allocatable :: rh(:),phi(:),alpha(:),beta(:)
  integer       , allocatable :: ref_ratio(:,:)
  integer       , allocatable :: hi_fine(:), hi_crse(:)
  type(flux_reg), pointer     :: fine_flx(:) => Null()
! type(box)                   :: fine_domain
  integer                     :: dm,stencil_order,n
  integer                     :: ng,nc
  integer                     :: nscal,bc_comp

  dm = umac(nlevs)%dim
  nscal = 2
  bc_comp = dm + nscal + 1

  stencil_order = 1

  allocate(ref_ratio(nlevs,dm),hi_fine(dm),hi_crse(dm))
  do n = 2,nlevs
     hi_fine = upb(layout_get_pd(la_tower(n  ))) + 1
     hi_crse = upb(layout_get_pd(la_tower(n-1))) + 1
     ref_ratio(n,:) = hi_fine(:) / hi_crse(:)
  end do
 
  allocate(rh(nlevs), phi(nlevs), alpha(nlevs), beta(nlevs))

  do n = 1, nlevs
     call multifab_build(   rh(n), la_tower(n),  1, 0)
     call multifab_build(  phi(n), la_tower(n),  1, 1)
     call multifab_build(alpha(n), la_tower(n),  1, 1)
     call multifab_build( beta(n), la_tower(n), dm, 1)

     call setval(alpha(n),ZERO,all=.true.)
     call setval(  phi(n),ZERO,all=.true.)

  end do

  call divumac(nlevs,umac,rh,dx,ref_ratio,verbose)

  call mk_mac_coeffs(nlevs,la_tower,rho,beta,the_bc_tower)

  allocate(fine_flx(2:nlevs))
  do n = 2,nlevs
     call flux_reg_build(fine_flx(n),la_tower(n),layout_get_pd(la_tower(n)))
  end do

  call mac_multigrid(nlevs,la_tower,rh,phi,fine_flx,alpha,beta,dx, &
                     the_bc_tower,bc_comp,stencil_order,mg_verbose)

! do n = 2, nlevs
!    fine_domain = layout_get_pd(la_tower(n))
!    call multifab_fill_ghost_cells(phi(n),phi(n-1),fine_domain, &
!                                   ng,ref_ratio(n,:), &
!                                   the_bc_tower%bc_tower_array(n-1)%adv_bc_level_array(0,:,:,:), &
!                                   1,dm+3,1)
! end do

  call mkumac(nlevs,rh,umac,phi,beta,fine_flx,dx,the_bc_tower,ref_ratio,verbose)

  do n = 1, nlevs
     call multifab_destroy(rh(n))
     call multifab_destroy(phi(n))
     call multifab_destroy(alpha(n))
     call multifab_destroy(beta(n))
  end do

  deallocate(rh)
  deallocate(phi)
  deallocate(alpha)
  deallocate(beta)

  contains

    subroutine divumac(nlevs,umac,rh,dx,ref_ratio,verbose)

      integer        , intent(in   ) :: nlevs
      type(multifab) , intent(inout) :: umac(:)
      type(multifab) , intent(inout) :: rh(:)
      real(kind=dp_t), intent(in   ) :: dx(:,:)
      integer        , intent(in   ) :: ref_ratio(:,:)
      integer        , intent(in   ) :: verbose
 
      real(kind=dp_t), pointer :: ump(:,:,:,:) 
      real(kind=dp_t), pointer :: rhp(:,:,:,:) 
      real(kind=dp_t)          :: rhmax
      integer :: i,dm

      dm = rh(nlevs)%dim

      do n = nlevs,2,-1
        call ml_edge_restriction(umac(n),umac(n-1),ref_ratio(n,:))
      end do

      do n = 1,nlevs
         do i = 1, umac(n)%nboxes
            if ( multifab_remote(umac(n), i) ) cycle
            ump => dataptr(umac(n), i)
            rhp => dataptr(rh(n)  , i)
            select case (dm)
               case (2)
                 call divumac_2d(ump(:,:,1,:), rhp(:,:,1,1), dx(n,:))
               case (3)
                 call divumac_3d(ump(:,:,:,:), rhp(:,:,:,1), dx(n,:))
            end select
         end do
      end do

      rhmax = norm_inf(rh(nlevs))
      do n = nlevs,2,-1
         call ml_cc_restriction(rh(n),rh(n-1),ref_ratio(n,:))
         rhmax = max(rhmax,norm_inf(rh(n-1)))
      end do

      if (verbose .eq. 1) then
         print *,' '
         print *,'... mac_projection: max of divu ',rhmax
      end if

    end subroutine divumac

    subroutine divumac_2d(umac,rh,dx)

!     real(kind=dp_t), intent(in   ) :: umac(-2:,-2:,:)
      real(kind=dp_t), intent(inout) :: umac(-2:,-2:,:)
      real(kind=dp_t), intent(inout) ::   rh( 0:, 0:)
      real(kind=dp_t), intent(in   ) ::   dx(:)

      integer :: i,j

      do j = 0, size(rh,dim=2)-1
      do i = 0, size(rh,dim=1)-1
         rh(i,j) = (umac(i+1,j,1) - umac(i,j,1)) / dx(1) + &
                   (umac(i,j+1,2) - umac(i,j,2)) / dx(2)
         rh(i,j) = -rh(i,j)
      end do
      end do

    end subroutine divumac_2d

    subroutine divumac_3d(umac,rh,dx)

      real(kind=dp_t), intent(in   ) :: umac(-2:,-2:,-2:,:)
      real(kind=dp_t), intent(inout) ::   rh( 0:, 0:, 0:)
      real(kind=dp_t), intent(in   ) :: dx(:)

      integer :: i,j,k

      do k = 0,size(rh,dim=3)-1
      do j = 0,size(rh,dim=2)-1
      do i = 0,size(rh,dim=1)-1
         rh(i,j,k) = (umac(i+1,j,k,1) - umac(i,j,k,1)) / dx(1) + &
                     (umac(i,j+1,k,2) - umac(i,j,k,2)) / dx(2) + &
                     (umac(i,j,k+1,3) - umac(i,j,k,3)) / dx(3)
         rh(i,j,k) = -rh(i,j,k)
      end do
      end do
      end do

    end subroutine divumac_3d

    subroutine mk_mac_coeffs(nlevs,la_tower,rho,beta,the_bc_tower)

      integer       , intent(in   ) :: nlevs
      type(layout)  , intent(inout) :: la_tower(:)
      type(multifab), intent(inout) :: rho(:)
      type(multifab), intent(inout) :: beta(:)
      type(bc_tower), intent(in   ) :: the_bc_tower
 
      type(box )               :: fine_domain
      real(kind=dp_t), pointer :: bp(:,:,:,:) 
      real(kind=dp_t), pointer :: rp(:,:,:,:) 
      integer :: i,dm,ng,ng_fill

      dm = rho(nlevs)%dim
      ng = rho(nlevs)%ng

      ng_fill = 1
      do n = 2, nlevs
         fine_domain = layout_get_pd(la_tower(n))
         call multifab_fill_ghost_cells(rho(n),rho(n-1),fine_domain, &
                                        ng_fill,ref_ratio(n,:), &
                                        the_bc_tower%bc_tower_array(n-1)%adv_bc_level_array(0,:,:,:), &
                                        1,dm+1,1)
      end do

      do n = 1, nlevs
         call multifab_fill_boundary(rho(n))
         do i = 1, rho(n)%nboxes
            if ( multifab_remote(rho(n), i) ) cycle
            rp => dataptr(rho(n) , i)
            bp => dataptr(beta(n), i)
            select case (dm)
               case (2)
                 call mk_mac_coeffs_2d(bp(:,:,1,:), rp(:,:,1,1), ng)
               case (3)
                 call mk_mac_coeffs_3d(bp(:,:,:,:), rp(:,:,:,1), ng)
            end select
         end do
      end do

    end subroutine mk_mac_coeffs

    subroutine mk_mac_coeffs_2d(beta,rho,ng)

      integer :: ng
      real(kind=dp_t), intent(inout) :: beta( -1:, -1:,:)
      real(kind=dp_t), intent(inout) ::  rho(-ng:,-ng:)

      integer :: i,j
      integer :: nx,ny
 
      nx = size(beta,dim=1) - 2
      ny = size(beta,dim=2) - 2

      do j = 0,ny-1
      do i = 0,nx
         beta(i,j,1) = TWO / (rho(i,j) + rho(i-1,j))
      end do
      end do

      do j = 0,ny
      do i = 0,nx-1
         beta(i,j,2) = TWO / (rho(i,j) + rho(i,j-1))
      end do
      end do

    end subroutine mk_mac_coeffs_2d

    subroutine mk_mac_coeffs_3d(beta,rho,ng)

      integer :: ng
      real(kind=dp_t), intent(inout) :: beta( -1:, -1:, -1:,:)
      real(kind=dp_t), intent(inout) ::  rho(-ng:,-ng:,-ng:)

      integer :: i,j,k
      integer :: nx,ny,nz
 
      nx = size(beta,dim=1) - 2
      ny = size(beta,dim=2) - 2
      nz = size(beta,dim=3) - 2

      do k = 0,nz-1
      do j = 0,ny-1
      do i = 0,nx
         beta(i,j,k,1) = TWO / (rho(i,j,k) + rho(i-1,j,k))
      end do
      end do
      end do

      do k = 0,nz-1
      do j = 0,ny
      do i = 0,nx-1
         beta(i,j,k,2) = TWO / (rho(i,j,k) + rho(i,j-1,k))
      end do
      end do
      end do

      do k = 0,nz
      do j = 0,ny-1
      do i = 0,nx-1
         beta(i,j,k,3) = TWO / (rho(i,j,k) + rho(i,j,k-1))
      end do
      end do
      end do

    end subroutine mk_mac_coeffs_3d

    subroutine mkumac(nlevs,rh,umac,phi,beta,fine_flx,dx,the_bc_tower,ref_ratio,verbose)

      integer       , intent(in   ) :: nlevs
      type(multifab), intent(inout) :: umac(:)
      type(multifab), intent(inout) ::   rh(:)
      type(multifab), intent(in   ) ::  phi(:)
      type(multifab), intent(in   ) :: beta(:)
      type(flux_reg), intent(in   ) :: fine_flx(2:)
      real(dp_t)    , intent(in   ) :: dx(:,:)
      type(bc_tower), intent(in   ) :: the_bc_tower
      integer       , intent(in   ) :: ref_ratio(:,:)
      integer       , intent(in   ) :: verbose

      integer :: i,dm
 
      type(bc_level)           :: bc
      real(kind=dp_t), pointer :: ump(:,:,:,:) 
      real(kind=dp_t), pointer :: php(:,:,:,:) 
      real(kind=dp_t), pointer :: rhp(:,:,:,:) 
      real(kind=dp_t), pointer ::  bp(:,:,:,:) 
      real(kind=dp_t), pointer :: lxp(:,:,:,:) 
      real(kind=dp_t), pointer :: hxp(:,:,:,:) 
      real(kind=dp_t), pointer :: lyp(:,:,:,:) 
      real(kind=dp_t), pointer :: hyp(:,:,:,:) 
      real(kind=dp_t), pointer :: lzp(:,:,:,:) 
      real(kind=dp_t), pointer :: hzp(:,:,:,:) 
      real(kind=dp_t)          :: rhmax

      dm = umac(nlevs)%dim

      do n = 1, nlevs
        bc = the_bc_tower%bc_tower_array(n)
        do i = 1, umac(n)%nboxes
          if ( multifab_remote(umac(n), i) ) cycle
          ump => dataptr(umac(n), i)
          rhp => dataptr(  rh(n), i)
          php => dataptr( phi(n), i)
           bp => dataptr(beta(n), i)
          select case (dm)
             case (2)
               if (n > 1) then
                 lxp => dataptr(fine_flx(n)%bmf(1,0), i)
                 hxp => dataptr(fine_flx(n)%bmf(1,1), i)
                 lyp => dataptr(fine_flx(n)%bmf(2,0), i)
                 hyp => dataptr(fine_flx(n)%bmf(2,1), i)
                 call mkumac_2d(rhp(:,:,1,1),ump(:,:,1,:), php(:,:,1,1), bp(:,:,1,:), &
                                lxp(:,:,1,1),hxp(:,:,1,1),lyp(:,:,1,1),hyp(:,:,1,1), &
                                dx(n,:),bc%ell_bc_level_array(i,:,:,dm+3))
               else 
                 call mkumac_2d_base(rhp(:,:,1,1),ump(:,:,1,:), php(:,:,1,1), bp(:,:,1,:), &
                                     dx(n,:),bc%ell_bc_level_array(i,:,:,dm+3))
               end if
             case (3)
               if (n > 1) then
                 lxp => dataptr(fine_flx(n)%bmf(1,0), i)
                 hxp => dataptr(fine_flx(n)%bmf(1,1), i)
                 lyp => dataptr(fine_flx(n)%bmf(2,0), i)
                 hyp => dataptr(fine_flx(n)%bmf(2,1), i)
                 lzp => dataptr(fine_flx(n)%bmf(3,0), i)
                 hzp => dataptr(fine_flx(n)%bmf(3,1), i)
                 call mkumac_3d(rhp(:,:,:,1),ump(:,:,:,:), php(:,:,:,1), bp(:,:,:,:), &
                                lxp(:,:,:,1),hxp(:,:,:,1),lyp(:,:,:,1),hyp(:,:,:,1), &
                                lzp(:,:,:,1),hzp(:,:,:,1),dx(n,:),&
                                bc%ell_bc_level_array(i,:,:,dm+3))
               else
                 call mkumac_3d_base(rhp(:,:,:,1),ump(:,:,:,:), php(:,:,:,1), bp(:,:,:,:), dx(n,:), &
                                     bc%ell_bc_level_array(i,:,:,dm+3))
               end if
          end select
        end do
      end do

      do n = nlevs,2,-1
         call ml_edge_restriction(umac(n),umac(n-1),ref_ratio(n,:))
      end do

      do n = nlevs,2,-1
         call ml_cc_restriction(rh(n),rh(n-1),ref_ratio(n,:))
      end do

      rhmax = ZERO
      do n = 1,nlevs
        rhmax = max(rhmax,norm_inf(rh(n)))
      end do

      if (verbose .eq. 1) then
         print *,'... mac_projection: max divu after projection',rhmax
         print *,' '
      end if

    end subroutine mkumac

    subroutine mkumac_2d_base(rh,umac,phi,beta,dx,press_bc)

      real(kind=dp_t), intent(inout) ::   rh( 0:, 0:)
      real(kind=dp_t), intent(inout) :: umac(-2:,-2:,:)
      real(kind=dp_t), intent(inout) ::  phi(-1:,-1:)
      real(kind=dp_t), intent(in   ) :: beta(-1:,-1:,:)
      real(kind=dp_t), intent(in   ) :: dx(:)
      integer        , intent(in   ) :: press_bc(:,:)

      real(kind=dp_t) :: gpx,gpy
      integer :: i,j,nx,ny

      nx = size(umac,dim=1) - 4
      ny = size(umac,dim=2) - 4

      if (press_bc(1,1) == BC_NEU) then
         do j = 0,ny-1
            phi(-1,j) = phi(0,j)
         end do
      else if (press_bc(1,1) == BC_DIR) then
         do j = 0,ny-1
            phi(-1,j) = -phi(0,j)
         end do
      end if
      if (press_bc(1,2) == BC_NEU) then
         do j = 0,ny-1
            phi(nx,j) = phi(nx-1,j)
         end do
      else if (press_bc(1,2) == BC_DIR) then
         do j = 0,ny-1
            phi(nx,j) = -phi(nx-1,j)
         end do
      end if
      if (press_bc(2,1) == BC_NEU) then
         do i = 0,nx-1
            phi(i,-1) = phi(i,0)
         end do
      else if (press_bc(2,1) == BC_DIR) then
         do i = 0,nx-1
            phi(i,-1) = -phi(i,0)
         end do
      end if
      if (press_bc(2,2) == BC_NEU) then
         do i = 0,nx-1
            phi(i,ny) = phi(i,ny-1)
         end do
      else if (press_bc(2,2) == BC_DIR) then
         do i = 0,nx-1
            phi(i,ny) = -phi(i,ny-1)
         end do
      end if

      do j = 0,ny-1
         do i = 0,nx
            gpx = (phi(i,j) - phi(i-1,j)) / dx(1)
            umac(i,j,1) = umac(i,j,1) - beta(i,j,1)*gpx
         end do
      end do

      do i = 0,nx-1
         do j = 0,ny
            gpy = (phi(i,j) - phi(i,j-1)) / dx(2)
            umac(i,j,2) = umac(i,j,2) - beta(i,j,2)*gpy
         end do
      end do

!     This is just a test
      rh    = ZERO
      do j = 0,ny-1
      do i = 0,nx-1
         rh(i,j) = (umac(i+1,j,1) - umac(i,j,1)) / dx(1) + &
                   (umac(i,j+1,2) - umac(i,j,2)) / dx(2)
      end do
      end do

    end subroutine mkumac_2d_base

    subroutine mkumac_2d(rh,umac,phi,beta, &
                         lo_x_flx,hi_x_flx,lo_y_flx,hi_y_flx, &
                         dx,press_bc)

      real(kind=dp_t), intent(inout) ::   rh( 0:, 0:)
      real(kind=dp_t), intent(inout) :: umac(-2:,-2:,:)
      real(kind=dp_t), intent(inout) ::  phi(-1:,-1:)
      real(kind=dp_t), intent(in   ) :: beta(-1:,-1:,:)
      real(kind=dp_t), intent(in   ) :: lo_x_flx(:,0:), lo_y_flx(0:,:)
      real(kind=dp_t), intent(in   ) :: hi_x_flx(:,0:), hi_y_flx(0:,:)
      real(kind=dp_t), intent(in   ) :: dx(:)
      integer        , intent(in   ) :: press_bc(:,:)

      real(kind=dp_t) :: gpx,gpy
      integer :: i,j,nx,ny

      nx = size(umac,dim=1) - 4
      ny = size(umac,dim=2) - 4

      if (press_bc(1,1) == BC_NEU) then
         do j = 0,ny-1
            phi(-1,j) = phi(0,j)
         end do
      else if (press_bc(1,1) == BC_DIR) then
         do j = 0,ny-1
            phi(-1,j) = -phi(0,j)
         end do
      end if
      if (press_bc(1,2) == BC_NEU) then
         do j = 0,ny-1
            phi(nx,j) = phi(nx-1,j)
         end do
      else if (press_bc(1,2) == BC_DIR) then
         do j = 0,ny-1
            phi(nx,j) = -phi(nx-1,j)
         end do
      end if
      if (press_bc(2,1) == BC_NEU) then
         do i = 0,nx-1
            phi(i,-1) = phi(i,0)
         end do
      else if (press_bc(2,1) == BC_DIR) then
         do i = 0,nx-1
            phi(i,-1) = -phi(i,0)
         end do
      end if
      if (press_bc(2,2) == BC_NEU) then
         do i = 0,nx-1
            phi(i,ny) = phi(i,ny-1)
         end do
      else if (press_bc(2,2) == BC_DIR) then
         do i = 0,nx-1
            phi(i,ny) = -phi(i,ny-1)
         end do
      end if

      do j = 0,ny-1
      do i = 0,nx-1
         rh(i,j) = (umac(i+1,j,1) - umac(i,j,1)) / dx(1) + &
                   (umac(i,j+1,2) - umac(i,j,2)) / dx(2)
      end do
      end do

      do j = 0,ny-1
         umac( 0,j,1) = umac( 0,j,1) + lo_x_flx(1,j) * dx(1)
         umac(nx,j,1) = umac(nx,j,1) + hi_x_flx(1,j) * dx(1)
         do i = 1,nx-1
            gpx = (phi(i,j) - phi(i-1,j)) / dx(1)
            umac(i,j,1) = umac(i,j,1) - beta(i,j,1)*gpx
         end do
      end do

      do i = 0,nx-1
         umac(i, 0,2) = umac(i, 0,2) + lo_y_flx(i,1) * dx(2)
         umac(i,ny,2) = umac(i,ny,2) + hi_y_flx(i,1) * dx(2)
         do j = 1,ny-1
            gpy = (phi(i,j) - phi(i,j-1)) / dx(2)
            umac(i,j,2) = umac(i,j,2) - beta(i,j,2)*gpy
         end do
      end do

      rh    = ZERO
      do j = 0,ny-1
      do i = 0,nx-1
         rh(i,j) = (umac(i+1,j,1) - umac(i,j,1)) / dx(1) + &
                   (umac(i,j+1,2) - umac(i,j,2)) / dx(2)
      end do
      end do

    end subroutine mkumac_2d

    subroutine mkumac_3d_base(rh,umac,phi,beta,dx,press_bc)

      real(kind=dp_t), intent(inout) ::   rh( 0:, 0:, 0:)
      real(kind=dp_t), intent(inout) :: umac(-2:,-2:,-2:,:)
      real(kind=dp_t), intent(inout) ::  phi(-1:,-1:,-1:)
      real(kind=dp_t), intent(in   ) :: beta(-1:,-1:,-1:,:)
      real(kind=dp_t), intent(in   ) :: dx(:)
      integer        , intent(in   ) :: press_bc(:,:)

      real(kind=dp_t) :: gpx,gpy,gpz
      integer :: i,j,k,nx,ny,nz

      nx = size(umac,dim=1) - 4
      ny = size(umac,dim=2) - 4
      nz = size(umac,dim=3) - 4

      if (press_bc(1,1) == BC_NEU) then
         do k = 0,nz-1
         do j = 0,ny-1
            phi(-1,j,k) = phi(0,j,k)
         end do
         end do
      else if (press_bc(1,1) == BC_DIR) then
         do k = 0,nz-1
         do j = 0,ny-1
            phi(-1,j,k) = -phi(0,j,k)
         end do
         end do
      end if
      if (press_bc(1,2) == BC_NEU) then
         do k = 0,nz-1
         do j = 0,ny-1
            phi(nx,j,k) = phi(nx-1,j,k)
         end do
         end do
      else if (press_bc(1,2) == BC_DIR) then
         do k = 0,nz-1
         do j = 0,ny-1
            phi(nx,j,k) = -phi(nx-1,j,k)
         end do
         end do
      end if
      if (press_bc(2,1) == BC_NEU) then
         do k = 0,nz-1
         do i = 0,nx-1
            phi(i,-1,k) = phi(i,0,k)
         end do
         end do
      else if (press_bc(2,1) == BC_DIR) then
         do k = 0,nz-1
         do i = 0,nx-1
            phi(i,-1,k) = -phi(i,0,k)
         end do
         end do
      end if
      if (press_bc(2,2) == BC_NEU) then
         do k = 0,nz-1
         do i = 0,nx-1
            phi(i,ny,k) = phi(i,ny-1,k)
         end do
         end do
      else if (press_bc(2,2) == BC_DIR) then
         do k = 0,nz-1
         do i = 0,nx-1
            phi(i,ny,k) = -phi(i,ny-1,k)
         end do
         end do
      end if
      if (press_bc(3,1) == BC_NEU) then
         do j = 0,ny-1
         do i = 0,nx-1
            phi(i,j,-1) = phi(i,j,0)
         end do
         end do
      else if (press_bc(3,1) == BC_DIR) then
         do j = 0,ny-1
         do i = 0,nx-1
            phi(i,j,-1) = -phi(i,j,0)
         end do
         end do
      end if
      if (press_bc(3,2) == BC_NEU) then
         do j = 0,ny-1
         do i = 0,nx-1
            phi(i,j,nz) = phi(i,j,nz-1)
         end do
         end do
      else if (press_bc(3,2) == BC_DIR) then
         do j = 0,ny-1
         do i = 0,nx-1
            phi(i,j,nz) = -phi(i,j,nz-1)
         end do
         end do
      end if

      do k = 0,nz-1
      do j = 0,ny-1
      do i = 0,nx
         gpx = (phi(i,j,k) - phi(i-1,j,k)) / dx(1)
         umac(i,j,k,1) = umac(i,j,k,1) - beta(i,j,k,1)*gpx
      end do
      end do
      end do

      do k = 0,nz-1
      do j = 0,ny
      do i = 0,nx-1
         gpy = (phi(i,j,k) - phi(i,j-1,k)) / dx(2)
         umac(i,j,k,2) = umac(i,j,k,2) - beta(i,j,k,2)*gpy
      end do
      end do
      end do

      do k = 0,nz
      do j = 0,ny-1
      do i = 0,nx-1
         gpz = (phi(i,j,k) - phi(i,j,k-1)) / dx(3)
         umac(i,j,k,3) = umac(i,j,k,3) - beta(i,j,k,3)*gpz
      end do
      end do
      end do

!     This is just a test
      do k = 0,nz-1
      do j = 0,ny-1
      do i = 0,nx-1
         rh(i,j,k) = (umac(i+1,j,k,1) - umac(i,j,k,1)) / dx(1) + &
                     (umac(i,j+1,k,2) - umac(i,j,k,2)) / dx(2) + &
                     (umac(i,j,k+1,3) - umac(i,j,k,3)) / dx(3)
      end do
      end do
      end do

    end subroutine mkumac_3d_base

    subroutine mkumac_3d(rh,umac,phi,beta,lo_x_flx,hi_x_flx,lo_y_flx,hi_y_flx, &
                         lo_z_flx,hi_z_flx,dx,press_bc)

      real(kind=dp_t), intent(inout) ::   rh( 0:, 0:, 0:)
      real(kind=dp_t), intent(inout) :: umac(-2:,-2:,-2:,:)
      real(kind=dp_t), intent(inout) ::  phi(-1:,-1:,-1:)
      real(kind=dp_t), intent(in   ) :: beta(-1:,-1:,-1:,:)
      real(kind=dp_t), intent(in   ) :: lo_x_flx(:,0:,0:), lo_y_flx(0:,:,0:), lo_z_flx(0:,0:,:)
      real(kind=dp_t), intent(in   ) :: hi_x_flx(:,0:,0:), hi_y_flx(0:,:,0:), hi_z_flx(0:,0:,:)
      real(kind=dp_t), intent(in   ) :: dx(:)
      integer        , intent(in   ) :: press_bc(:,:)

      real(kind=dp_t) :: gpx,gpy,gpz
      integer :: i,j,k,nx,ny,nz

      nx = size(umac,dim=1) - 4
      ny = size(umac,dim=2) - 4
      nz = size(umac,dim=3) - 4

      if (press_bc(1,1) == BC_NEU) then
         do k = 0,nz-1
         do j = 0,ny-1
            phi(-1,j,k) = phi(0,j,k)
         end do
         end do
      else if (press_bc(1,1) == BC_DIR) then
         do k = 0,nz-1
         do j = 0,ny-1
            phi(-1,j,k) = -phi(0,j,k)
         end do
         end do
      end if
      if (press_bc(1,2) == BC_NEU) then
         do k = 0,nz-1
         do j = 0,ny-1
            phi(nx,j,k) = phi(nx-1,j,k)
         end do
         end do
      else if (press_bc(1,2) == BC_DIR) then
         do k = 0,nz-1
         do j = 0,ny-1
            phi(nx,j,k) = -phi(nx-1,j,k)
         end do
         end do
      end if
      if (press_bc(2,1) == BC_NEU) then
         do k = 0,nz-1
         do i = 0,nx-1
            phi(i,-1,k) = phi(i,0,k)
         end do
         end do
      else if (press_bc(2,1) == BC_DIR) then
         do k = 0,nz-1
         do i = 0,nx-1
            phi(i,-1,k) = -phi(i,0,k)
         end do
         end do
      end if
      if (press_bc(2,2) == BC_NEU) then
         do k = 0,nz-1
         do i = 0,nx-1
            phi(i,ny,k) = phi(i,ny-1,k)
         end do
         end do
      else if (press_bc(2,2) == BC_DIR) then
         do k = 0,nz-1
         do i = 0,nx-1
            phi(i,ny,k) = -phi(i,ny-1,k)
         end do
         end do
      end if
      if (press_bc(3,1) == BC_NEU) then
         do j = 0,ny-1
         do i = 0,nx-1
            phi(i,j,-1) = phi(i,j,0)
         end do
         end do
      else if (press_bc(3,1) == BC_DIR) then
         do j = 0,ny-1
         do i = 0,nx-1
            phi(i,j,-1) = -phi(i,j,0)
         end do
         end do
      end if
      if (press_bc(3,2) == BC_NEU) then
         do j = 0,ny-1
         do i = 0,nx-1
            phi(i,j,nz) = phi(i,j,nz-1)
         end do
         end do
      else if (press_bc(3,2) == BC_DIR) then
         do j = 0,ny-1
         do i = 0,nx-1
            phi(i,j,nz) = -phi(i,j,nz-1)
         end do
         end do
      end if

      do k = 0,nz-1
      do j = 0,ny-1
         umac( 0,j,k,1) = umac( 0,j,k,1) - lo_x_flx(1,j,k)
         umac(nx,j,k,1) = umac(nx,j,k,1) - hi_x_flx(1,j,k)
         do i = 1,nx-1
            gpx = (phi(i,j,k) - phi(i-1,j,k)) / dx(1)
            umac(i,j,k,1) = umac(i,j,k,1) - beta(i,j,k,1)*gpx
         end do
      end do
      end do

      do k = 0,nz-1
      do i = 0,nx-1
         umac(i, 0,k,2) = umac(i, 0,k,2) - lo_y_flx(i,1,k)
         umac(i,ny,k,2) = umac(i,ny,k,2) - hi_y_flx(i,1,k)
         do j = 1,ny-1
            gpy = (phi(i,j,k) - phi(i,j-1,k)) / dx(2)
            umac(i,j,k,2) = umac(i,j,k,2) - beta(i,j,k,2)*gpy
         end do
      end do
      end do

      do j = 0,ny-1
      do i = 0,nx-1
         umac(i,j, 0,3) = umac(i,j, 0,3) - lo_z_flx(i,j,1)
         umac(i,j,nz,3) = umac(i,j,nz,3) - hi_z_flx(i,j,1)
         do k = 1,nz-1
            gpz = (phi(i,j,k) - phi(i,j,k-1)) / dx(3)
            umac(i,j,k,3) = umac(i,j,k,3) - beta(i,j,k,3)*gpz
         end do
      end do
      end do

!     This is just a test
      do k = 0,nz-1
      do j = 0,ny-1
      do i = 0,nx-1
         rh(i,j,k) = (umac(i+1,j,k,1) - umac(i,j,k,1)) / dx(1) + &
                     (umac(i,j+1,k,2) - umac(i,j,k,2)) / dx(2) + &
                     (umac(i,j,k+1,3) - umac(i,j,k,3)) / dx(3)
      end do
      end do
      end do

    end subroutine mkumac_3d

end subroutine macproject

subroutine mac_multigrid(nlevs,la_tower,rh,phi,fine_flx,alpha,beta,dx, &
                         the_bc_tower,bc_comp,stencil_order,mg_verbose)

  use f2kcli
  use stencil_module
  use coeffs_module
  use mg_module
  use list_box_module
  use itsol_module
  use sparse_solve_module
  use ml_solve_module
  use bl_mem_stat_module
  use box_util_module
  use bl_IO_module

  integer     ,intent(in   ) :: nlevs
  type(layout),intent(inout) :: la_tower(:)
  integer     ,intent(in   ) :: stencil_order
  integer     ,intent(in   ) :: mg_verbose

  real(dp_t), intent(in) :: dx(:,:)
  type(bc_tower), intent(in) :: the_bc_tower
  integer     ,intent(in   ) :: bc_comp

  type(layout  ) :: la
  type(boxarray) :: pdv
  type(box     ) :: pd

  type(multifab), allocatable :: coeffs(:)

  type(multifab), intent(in   ) :: alpha(:), beta(:)
  type(multifab), intent(inout) ::    rh(:),  phi(:)
  type(flux_reg), intent(inout) :: fine_flx(2:)

  type( multifab) :: ss
  type(imultifab) :: mm
  type(sparse) :: sparse_object
  type(mg_tower), allocatable :: mgt(:)
  integer i, dm, ns

  integer :: test
  integer, allocatable :: ref_ratio(:)
  integer, allocatable :: hi_fine(:)
  integer, allocatable :: hi_crse(:)
  real(dp_t) :: snrm(2)

  ! MG solver defaults
  integer :: bottom_solver, bottom_max_iter
  real(dp_t) :: bottom_solver_eps
  real(dp_t) :: eps
  integer :: max_iter
  integer :: min_width
  integer :: max_nlevel
  integer :: verbose
  integer :: n, nu1, nu2, gamma, cycle, solver, smoother
  integer :: max_nlevel_in
  real(dp_t) :: omega
  logical :: nodal(rh(nlevs)%dim)

  real(dp_t) :: xa(rh(nlevs)%dim), xb(rh(nlevs)%dim)

  !! Defaults:

  dm             = rh(nlevs)%dim

  allocate(mgt(nlevs))
  allocate(ref_ratio(dm))
  allocate(hi_fine(dm))
  allocate(hi_crse(dm))

  test           = 0

  max_nlevel        = mgt(nlevs)%max_nlevel
  max_iter          = mgt(nlevs)%max_iter
  eps               = mgt(nlevs)%eps
  solver            = mgt(nlevs)%solver
  smoother          = mgt(nlevs)%smoother
  nu1               = mgt(nlevs)%nu1
  nu2               = mgt(nlevs)%nu2
  gamma             = mgt(nlevs)%gamma
  omega             = mgt(nlevs)%omega
  cycle             = mgt(nlevs)%cycle
  bottom_solver     = mgt(nlevs)%bottom_solver
  bottom_solver_eps = mgt(nlevs)%bottom_solver_eps
  bottom_max_iter   = mgt(nlevs)%bottom_max_iter
  min_width         = mgt(nlevs)%min_width
  verbose           = mgt(nlevs)%verbose

! Note: put this here to minimize asymmetries - ASA
  eps = 1.d-12

  bottom_solver = 0
  
  nodal = .false.

  if ( test /= 0 .AND. max_iter == mgt(nlevs)%max_iter ) &
     max_iter = 1000

  ns = 1 + dm*3

  do n = nlevs, 1, -1

     if (n == 1) then
        max_nlevel_in = max_nlevel
     else
        hi_fine = upb(layout_get_pd(la_tower(n  ))) + 1
        hi_crse = upb(layout_get_pd(la_tower(n-1))) + 1
        ref_ratio = hi_fine / hi_crse
        if ( all(ref_ratio == 2) ) then
           max_nlevel_in = 1
        else if ( all(ref_ratio == 4) ) then
           max_nlevel_in = 2
        else
           call bl_error("MAC_MULTIGRID: confused about ref_ratio")
        end if
     end if

     pd = layout_get_pd(la_tower(n))

     call mg_tower_build(mgt(n), la_tower(n), pd, &
                         the_bc_tower%bc_tower_array(n)%ell_bc_level_array(0,:,:,bc_comp), &
          dh = dx(n,:), &
          ns = ns, &
          smoother = smoother, &
          nu1 = nu1, &
          nu2 = nu2, &
          gamma = gamma, &
          cycle = cycle, &
          omega = omega, &
          bottom_solver = bottom_solver, &
          bottom_max_iter = bottom_max_iter, &
          bottom_solver_eps = bottom_solver_eps, &
          max_iter = max_iter, &
          max_nlevel = max_nlevel_in, &
          min_width = min_width, &
          eps = eps, &
          verbose = verbose, &
          nodal = nodal)

  end do

  !! Fill coefficient array

  do n = nlevs,1,-1

     allocate(coeffs(mgt(n)%nlevels))

     la = la_tower(n)
     pd = layout_get_pd(la)

     call multifab_build(coeffs(mgt(n)%nlevels), la, 1+dm, 1)
     call multifab_copy_c(coeffs(mgt(n)%nlevels),1,alpha(n),1, 1,all=.true.)
     call multifab_copy_c(coeffs(mgt(n)%nlevels),2, beta(n),1,dm,all=.true.)

     do i = mgt(n)%nlevels-1, 1, -1
        call multifab_build(coeffs(i), mgt(n)%ss(i)%la, 1+dm, 1)
        call setval(coeffs(i), ZERO, 1, dm+1, all=.true.)
        call coarsen_coeffs(coeffs(i+1),coeffs(i))
     end do

     if (n > 1) then
        hi_fine = upb(layout_get_pd(la_tower(n  ))) + 1
        hi_crse = upb(layout_get_pd(la_tower(n-1))) + 1
        ref_ratio = hi_fine / hi_crse
        xa = HALF*ref_ratio*mgt(n)%dh(:,mgt(n)%nlevels)
        xb = HALF*ref_ratio*mgt(n)%dh(:,mgt(n)%nlevels)
     else
        xa = ZERO
        xb = ZERO
     end if

     do i = mgt(n)%nlevels, 1, -1
        pdv = layout_boxarray(mgt(n)%ss(i)%la)
        call stencil_fill_cc(mgt(n)%ss(i), coeffs(i), mgt(n)%dh(:,i), &
             pdv, mgt(n)%mm(i), xa, xb, pd, stencil_order, &
             the_bc_tower%bc_tower_array(n)%ell_bc_level_array(0,:,:,dm+3))
     end do

     if ( n == 1 .and. bottom_solver == 3 ) then
        call sparse_build(mgt(n)%sparse_object, mgt(n)%ss(1), &
             mgt(n)%mm(1), mgt(n)%ss(1)%la, stencil_order, mgt(nlevs)%verbose)
     end if
     do i = mgt(n)%nlevels, 1, -1
        call multifab_destroy(coeffs(i))
     end do
     deallocate(coeffs)

  end do

  call ml_cc_solve(la_tower, mgt, rh, phi, fine_flx, &
                   the_bc_tower%bc_tower_array(nlevs)%ell_bc_level_array(0,:,:,dm+3), &
                   stencil_order)

  do n = 1,nlevs
     call multifab_fill_boundary(phi(n))
  end do

  if ( test == 3 ) then
     call sparse_destroy(sparse_object)
  end if
  if ( test > 0 ) then
     call destroy(ss)
     call destroy(mm)
  end if

  do n = 1, nlevs
     call mg_tower_destroy(mgt(n))
  end do
  deallocate(mgt)
  deallocate(ref_ratio)

end subroutine mac_multigrid

end module macproject_module
