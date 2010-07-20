module update_module
  
  use bl_types
  use multifab_module
  use define_bc_module
  use ml_layout_module

  implicit none

  private

  public :: update

contains

  subroutine update(mla,sold,umac,sedge,flux,force,snew,dx,dt,is_vel,is_cons, &
                    the_bc_level)

    use bl_constants_module
    use multifab_physbc_module
    use ml_restriction_module, only: ml_cc_restriction
    use multifab_fill_ghost_module

    type(ml_layout)   , intent(in   ) :: mla
    type(multifab)    , intent(in   ) :: sold(:)
    type(multifab)    , intent(in   ) :: umac(:,:)
    type(multifab)    , intent(in   ) :: sedge(:,:)
    type(multifab)    , intent(in   ) :: flux(:,:)
    type(multifab)    , intent(in   ) :: force(:)
    type(multifab)    , intent(inout) :: snew(:)
    real(kind = dp_t) , intent(in   ) :: dx(:,:),dt
    logical           , intent(in   ) :: is_vel,is_cons(:)
    type(bc_level)    , intent(in   ) :: the_bc_level(:)

    ! local
    real(kind=dp_t), pointer :: sop(:,:,:,:)
    real(kind=dp_t), pointer :: snp(:,:,:,:)
    real(kind=dp_t), pointer :: ump(:,:,:,:)
    real(kind=dp_t), pointer :: vmp(:,:,:,:)
    real(kind=dp_t), pointer :: wmp(:,:,:,:)
    real(kind=dp_t), pointer :: sepx(:,:,:,:)
    real(kind=dp_t), pointer :: sepy(:,:,:,:)
    real(kind=dp_t), pointer :: sepz(:,:,:,:)
    real(kind=dp_t), pointer :: fluxpx(:,:,:,:)
    real(kind=dp_t), pointer :: fluxpy(:,:,:,:)
    real(kind=dp_t), pointer :: fluxpz(:,:,:,:)
    real(kind=dp_t), pointer :: fp(:,:,:,:)

    integer :: lo(get_dim(sold(1))),hi(get_dim(sold(1)))
    integer :: i,ng,dm,nscal,n,nlevs

    nlevs = mla%nlevel
    dm    = mla%dim

    ng = nghost(sold(1))
    nscal = multifab_ncomp(sold(1))

    do n=1,nlevs

       do i = 1, nboxes(sold(n))
          if ( multifab_remote(sold(n),i) ) cycle
          sop    => dataptr(sold(n),i)
          snp    => dataptr(snew(n),i)
          ump    => dataptr(umac(n,1),i)
          vmp    => dataptr(umac(n,2),i)
          sepx   => dataptr(sedge(n,1),i)
          sepy   => dataptr(sedge(n,2),i)
          fluxpx => dataptr(flux(n,1),i)
          fluxpy => dataptr(flux(n,2),i)
          fp     => dataptr(force(n),i)
          lo = lwb(get_box(sold(n),i))
          hi = upb(get_box(sold(n),i))
          select case (dm)
          case (2)
             call update_2d(sop(:,:,1,:), ump(:,:,1,1), vmp(:,:,1,1), &
                  sepx(:,:,1,:), sepy(:,:,1,:), &
                  fluxpx(:,:,1,:), fluxpy(:,:,1,:), &
                  fp(:,:,1,:) , snp(:,:,1,:), &
                  lo, hi, ng, dx(n,:), dt, is_vel, is_cons)
          case (3)
             wmp    => dataptr( umac(n,3),i)
             sepz   => dataptr(sedge(n,3),i)
             fluxpz => dataptr( flux(n,3),i)
             call update_3d(sop(:,:,:,:), ump(:,:,:,1), vmp(:,:,:,1), wmp(:,:,:,1), &
                  sepx(:,:,:,:), sepy(:,:,:,:), sepz(:,:,:,:), &
                  fluxpx(:,:,:,:), fluxpy(:,:,:,:), fluxpz(:,:,:,:), &
                  fp(:,:,:,:) , snp(:,:,:,:), &
                  lo, hi, ng, dx(n,:), dt, is_vel, is_cons)
          end select
       end do

       call multifab_fill_boundary(snew(n))

       if (is_vel) then
          call multifab_physbc(snew(n),1,   1,   dm,the_bc_level(n))
       else
          call multifab_physbc(snew(n),1,dm+1,nscal,the_bc_level(n))
       end if

    enddo ! end loop over levels

    do n = nlevs,2,-1
       call ml_cc_restriction(snew(n-1),snew(n),mla%mba%rr(n-1,:))
    end do

    do n = 2,nlevs
       if (.not. is_vel) then

          call multifab_fill_ghost_cells(snew(n),snew(n-1),ng,mla%mba%rr(n-1,:), &
                                         the_bc_level(n-1),the_bc_level(n), &
                                         1,dm+1,nscal)

       else if (is_vel) then

          call multifab_fill_ghost_cells(snew(n),snew(n-1),ng,mla%mba%rr(n-1,:), &
                                         the_bc_level(n-1),the_bc_level(n), &
                                         1,1,dm)

       end if

    enddo ! end loop over levels

  end subroutine update

  subroutine update_2d(sold,umac,vmac,sedgex,sedgey,fluxx,fluxy,force,snew,&
                       lo,hi,ng,dx,dt,is_vel,is_cons)

    use bl_constants_module

    integer           , intent(in   ) :: lo(:), hi(:), ng
    real (kind = dp_t), intent(in   ) ::    sold(lo(1)-ng:,lo(2)-ng:,:)  
    real (kind = dp_t), intent(  out) ::    snew(lo(1)-ng:,lo(2)-ng:,:)  
    real (kind = dp_t), intent(in   ) ::    umac(lo(1)- 1:,lo(2)- 1:)  
    real (kind = dp_t), intent(in   ) ::    vmac(lo(1)- 1:,lo(2)- 1:)  
    real (kind = dp_t), intent(in   ) ::  sedgex(lo(1)   :,lo(2)   :,:)  
    real (kind = dp_t), intent(in   ) ::  sedgey(lo(1)   :,lo(2)   :,:)  
    real (kind = dp_t), intent(in   ) ::   fluxx(lo(1)   :,lo(2)   :,:)  
    real (kind = dp_t), intent(in   ) ::   fluxy(lo(1)   :,lo(2)   :,:) 
    real (kind = dp_t), intent(in   ) ::   force(lo(1)- 1:,lo(2)- 1:,:)  
    real (kind = dp_t), intent(in   ) :: dx(:)
    real (kind = dp_t), intent(in   ) :: dt
    logical           , intent(in   ) :: is_vel
    logical           , intent(in   ) :: is_cons(:)

    integer :: i, j, comp
    real (kind = dp_t) ubar,vbar
    real (kind = dp_t) ugradu,ugradv,ugrads
    real (kind = dp_t) :: divsu

    if (.not. is_vel) then

       do comp = 1,size(sold,dim=3)
          if (is_cons(comp)) then
             do j = lo(2), hi(2)
                do i = lo(1), hi(1)
                   divsu = (fluxx(i+1,j,comp)-fluxx(i,j,comp))/dx(1) &
                         + (fluxy(i,j+1,comp)-fluxy(i,j,comp))/dx(2)
                   snew(i,j,comp) = sold(i,j,comp) - dt * divsu + dt * force(i,j,comp)
                enddo
             enddo
          else
             do j = lo(2), hi(2)
                do i = lo(1), hi(1)
                   ubar = HALF*(umac(i,j) + umac(i+1,j))
                   vbar = HALF*(vmac(i,j) + vmac(i,j+1))
                   ugrads = ubar*(sedgex(i+1,j,comp) - sedgex(i,j,comp))/dx(1) + &
                            vbar*(sedgey(i,j+1,comp) - sedgey(i,j,comp))/dx(2)
                   snew(i,j,comp) = sold(i,j,comp) - dt * ugrads + dt * force(i,j,comp)
                enddo
             enddo
          end if
          print *,'OLD NEW 47: ',sold(47,120,comp), snew(47,120,comp)
          print *,'OLD NEW 80: ',sold(80,120,comp), snew(80,120,comp)
       end do

    else if (is_vel) then 

       do j = lo(2), hi(2)
          do i = lo(1), hi(1)

             ubar = HALF*(umac(i,j) + umac(i+1,j))
             vbar = HALF*(vmac(i,j) + vmac(i,j+1))

             ugradu = ubar*(sedgex(i+1,j,1) - sedgex(i,j,1))/dx(1) + &
                  vbar*(sedgey(i,j+1,1) - sedgey(i,j,1))/dx(2)

             ugradv = ubar*(sedgex(i+1,j,2) - sedgex(i,j,2))/dx(1) + &
                  vbar*(sedgey(i,j+1,2) - sedgey(i,j,2))/dx(2)

             snew(i,j,1) = sold(i,j,1) - dt * ugradu + dt * force(i,j,1)
             snew(i,j,2) = sold(i,j,2) - dt * ugradv + dt * force(i,j,2)

          enddo
       enddo
    end if

  end subroutine update_2d

  subroutine update_3d(sold,umac,vmac,wmac,sedgex,sedgey,sedgez,fluxx,fluxy,fluxz, &
                       force,snew,lo,hi,ng,dx,dt,is_vel,is_cons)

    use bl_constants_module

    integer           , intent(in   ) :: lo(:), hi(:), ng
    real (kind = dp_t), intent(in   ) ::    sold(lo(1)-ng:,lo(2)-ng:,lo(3)-ng:,:)  
    real (kind = dp_t), intent(  out) ::    snew(lo(1)-ng:,lo(2)-ng:,lo(3)-ng:,:)  
    real (kind = dp_t), intent(in   ) ::    umac(lo(1)- 1:,lo(2)- 1:,lo(3)- 1:)  
    real (kind = dp_t), intent(in   ) ::    vmac(lo(1)- 1:,lo(2)- 1:,lo(3)- 1:)  
    real (kind = dp_t), intent(in   ) ::    wmac(lo(1)- 1:,lo(2)- 1:,lo(3)- 1:)  
    real (kind = dp_t), intent(in   ) ::  sedgex(lo(1)   :,lo(2)   :,lo(3)   :,:)  
    real (kind = dp_t), intent(in   ) ::  sedgey(lo(1)   :,lo(2)   :,lo(3)   :,:)  
    real (kind = dp_t), intent(in   ) ::  sedgez(lo(1)   :,lo(2)   :,lo(3)   :,:)  
    real (kind = dp_t), intent(in   ) ::   fluxx(lo(1)   :,lo(2)   :,lo(3)   :,:)  
    real (kind = dp_t), intent(in   ) ::   fluxy(lo(1)   :,lo(2)   :,lo(3)   :,:)  
    real (kind = dp_t), intent(in   ) ::   fluxz(lo(1)   :,lo(2)   :,lo(3)   :,:) 
    real (kind = dp_t), intent(in   ) ::   force(lo(1)- 1:,lo(2)- 1:,lo(3)- 1:,:)  
    real (kind = dp_t), intent(in   ) :: dx(:)
    real (kind = dp_t), intent(in   ) :: dt
    logical           , intent(in   ) :: is_vel
    logical           , intent(in   ) :: is_cons(:)

    !     Local variables
    integer :: i, j, k, comp
    real (kind = dp_t) ubar,vbar,wbar
    real (kind = dp_t) :: ugradu,ugradv,ugradw,ugrads
    real (kind = dp_t) :: divsu

    if (.not. is_vel) then

       do comp = 1,size(sold,dim=4)
          if (is_cons(comp)) then
             do k = lo(3), hi(3)
                do j = lo(2), hi(2)
                   do i = lo(1), hi(1)
                      divsu = (fluxx(i+1,j,k,comp)-fluxx(i,j,k,comp))/dx(1) &
                            + (fluxy(i,j+1,k,comp)-fluxy(i,j,k,comp))/dx(2) &
                            + (fluxz(i,j,k+1,comp)-fluxz(i,j,k,comp))/dx(3)
                      snew(i,j,k,comp) = sold(i,j,k,comp) - dt * divsu + dt * force(i,j,k,comp)
                   enddo
                enddo
             enddo

          else 

             do k = lo(3), hi(3)
                do j = lo(2), hi(2)
                   do i = lo(1), hi(1)
                      ubar = half*(umac(i,j,k) + umac(i+1,j,k))
                      vbar = half*(vmac(i,j,k) + vmac(i,j+1,k))
                      wbar = half*(wmac(i,j,k) + wmac(i,j,k+1))
                      ugrads = ubar*(sedgex(i+1,j,k,comp) - sedgex(i,j,k,comp))/dx(1) + &
                               vbar*(sedgey(i,j+1,k,comp) - sedgey(i,j,k,comp))/dx(2) + &
                               wbar*(sedgez(i,j,k+1,comp) - sedgez(i,j,k,comp))/dx(3)
                      snew(i,j,k,comp) = sold(i,j,k,comp) - dt * ugrads + dt * force(i,j,k,comp)
                   enddo
                enddo
             enddo
          end if
       enddo

    else if (is_vel) then

       do k = lo(3), hi(3)
          do j = lo(2), hi(2)
             do i = lo(1), hi(1)
                ubar = half*(umac(i,j,k) + umac(i+1,j,k))
                vbar = half*(vmac(i,j,k) + vmac(i,j+1,k))
                wbar = half*(wmac(i,j,k) + wmac(i,j,k+1))

                ugradu = ubar*(sedgex(i+1,j,k,1) - sedgex(i,j,k,1))/dx(1) + &
                         vbar*(sedgey(i,j+1,k,1) - sedgey(i,j,k,1))/dx(2) + &
                         wbar*(sedgez(i,j,k+1,1) - sedgez(i,j,k,1))/dx(3)

                ugradv = ubar*(sedgex(i+1,j,k,2) - sedgex(i,j,k,2))/dx(1)
!               ugradv = ubar*(sedgex(i+1,j,k,2) - sedgex(i,j,k,2))/dx(1) + &
!                        vbar*(sedgey(i,j+1,k,2) - sedgey(i,j,k,2))/dx(2) + &
!                        wbar*(sedgez(i,j,k+1,2) - sedgez(i,j,k,2))/dx(3)

                ugradw = ubar*(sedgex(i+1,j,k,3) - sedgex(i,j,k,3))/dx(1) + &
                         vbar*(sedgey(i,j+1,k,3) - sedgey(i,j,k,3))/dx(2) + &
                         wbar*(sedgez(i,j,k+1,3) - sedgez(i,j,k,3))/dx(3)

                snew(i,j,k,1) = sold(i,j,k,1) - dt * ugradu + dt * force(i,j,k,1)
                snew(i,j,k,2) = sold(i,j,k,2) - dt * ugradv + dt * force(i,j,k,2)
                snew(i,j,k,3) = sold(i,j,k,3) - dt * ugradw + dt * force(i,j,k,3)
             enddo
          enddo
       enddo

    end if

  end subroutine update_3d

end module update_module
