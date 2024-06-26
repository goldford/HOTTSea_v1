MODULE diaar5
   !!======================================================================
   !!                       ***  MODULE  diaar5  ***
   !! AR5 diagnostics
   !!======================================================================
   !! History :  3.2  !  2009-11  (S. Masson)  Original code
   !!            3.3  !  2010-10  (C. Ethe, G. Madec) reorganisation of initialisation phase + merge TRC-TRA
#if defined key_botpreonly
   !!                 !  2017-10  (Xianmin Hu) add key_botpreonly for bottom pressure output only     
#endif
   !!----------------------------------------------------------------------
#if defined key_diaar5   || defined key_esopa
   !!----------------------------------------------------------------------
   !!   'key_diaar5'  :                           activate ar5 diagnotics
   !!----------------------------------------------------------------------
   !!   dia_ar5       : AR5 diagnostics
   !!   dia_ar5_init  : initialisation of AR5 diagnostics
   !!----------------------------------------------------------------------
   USE oce            ! ocean dynamics and active tracers 
   USE dom_oce        ! ocean space and time domain
   USE eosbn2         ! equation of state                (eos_bn2 routine)
   USE lib_mpp        ! distribued memory computing library
   USE iom            ! I/O manager library
   USE timing         ! preformance summary
   USE wrk_nemo       ! working arrays
   USE fldread        ! type FLD_N
   USE phycst         ! physical constant
   USE in_out_manager  ! I/O manager
   USE zdfddm
   USE zdf_oce

   IMPLICIT NONE
   PRIVATE

   PUBLIC   dia_ar5        ! routine called in step.F90 module
   PUBLIC   dia_ar5_init   ! routine called in opa.F90 module
   PUBLIC   dia_ar5_alloc  ! routine called in nemogcm.F90 module

   LOGICAL, PUBLIC, PARAMETER :: lk_diaar5 = .TRUE.   ! coupled flag

   REAL(wp), ALLOCATABLE, SAVE, DIMENSION(:,:  ) ::   thick0       ! ocean thickness (interior domain)
#if !defined key_botpreonly
   REAL(wp)                         ::   vol0         ! ocean volume (interior domain)
   REAL(wp)                         ::   area_tot     ! total ocean surface (interior domain)
   REAL(wp), ALLOCATABLE, SAVE, DIMENSION(:,:  ) ::   area         ! cell surface (interior domain)
   REAL(wp), ALLOCATABLE, SAVE, DIMENSION(:,:,:) ::   sn0          ! initial salinity
#endif
      
   !! * Substitutions
#  include "domzgr_substitute.h90"
#  include "zdfddm_substitute.h90"
   !!----------------------------------------------------------------------
   !! NEMO/OPA 3.3 , NEMO Consortium (2010)
   !! $Id: diaar5.F90 8220 2017-06-26 16:17:34Z lovato $
   !! Software governed by the CeCILL licence     (NEMOGCM/NEMO_CeCILL.txt)
   !!----------------------------------------------------------------------
CONTAINS

   FUNCTION dia_ar5_alloc()
      !!----------------------------------------------------------------------
      !!                    ***  ROUTINE dia_ar5_alloc  ***
      !!----------------------------------------------------------------------
      INTEGER :: dia_ar5_alloc
      !!----------------------------------------------------------------------
      !
#if !defined key_botpreonly
      ALLOCATE( area(jpi,jpj), thick0(jpi,jpj) , sn0(jpi,jpj,jpk) , STAT=dia_ar5_alloc )
#else
      ALLOCATE( thick0(jpi,jpj) , STAT=dia_ar5_alloc )
#endif
      !
      IF( lk_mpp             )   CALL mpp_sum ( dia_ar5_alloc )
      IF( dia_ar5_alloc /= 0 )   CALL ctl_warn('dia_ar5_alloc: failed to allocate arrays')
      !
   END FUNCTION dia_ar5_alloc


   SUBROUTINE dia_ar5( kt )
      !!----------------------------------------------------------------------
      !!                    ***  ROUTINE dia_ar5  ***
      !!
      !! ** Purpose :   compute and output some AR5 diagnostics
      !!----------------------------------------------------------------------
      !
      INTEGER, INTENT( in ) ::   kt   ! ocean time-step index
      !
      INTEGER  ::   ji, jj, jk                      ! dummy loop arguments
      REAL(wp) ::   zvolssh, zvol, zssh_steric, zztmp, zarho, ztemp, zsal, zmass
      REAL(wp) ::   zaw, zbw, zrw
      !
      REAL(wp), POINTER, DIMENSION(:,:)     :: zarea_ssh , zbotpres       ! 2D workspace 
      REAL(wp), POINTER, DIMENSION(:,:)     :: zpe                        ! 2D workspace 
      REAL(wp), POINTER, DIMENSION(:,:,:)   :: zrhd , zrhop               ! 3D workspace
      REAL(wp), POINTER, DIMENSION(:,:,:,:) :: ztsn                       ! 4D workspace
      !!--------------------------------------------------------------------
      IF( nn_timing == 1 )   CALL timing_start('dia_ar5')

      !Call to init moved to here so that we can call iom_use in the
      !initialisation
      IF( kt == nit000 )     CALL dia_ar5_init
 
#if !defined key_botpreonly
      CALL wrk_alloc( jpi , jpj              , zarea_ssh , zbotpres, zpe )
      CALL wrk_alloc( jpi , jpj , jpk        , zrhd      , zrhop         )
      CALL wrk_alloc( jpi , jpj , jpk , jpts , ztsn                      )
#else
      CALL wrk_alloc( jpi , jpj              , zbotpres                  )
      CALL wrk_alloc( jpi , jpj , jpk        , zrhd      , zrhop         )
#endif

#if !defined key_botpreonly
      zarea_ssh(:,:) = area(:,:) * sshn(:,:)

      !                                         ! total volume of liquid seawater
      zvolssh = SUM( zarea_ssh(:,:) ) 
      IF( lk_mpp )   CALL mpp_sum( zvolssh )
      zvol = vol0 + zvolssh
      
      CALL iom_put( 'voltot', zvol               )
      CALL iom_put( 'sshtot', zvolssh / area_tot )
      CALL iom_put( 'sshdyn', sshn(:,:) - (zvolssh / area_tot) )

      !                     
      IF( iom_use('sshthster')) THEN
         ztsn(:,:,:,jp_tem) = tsn(:,:,:,jp_tem)                    ! thermosteric ssh
         ztsn(:,:,:,jp_sal) = sn0(:,:,:)
         CALL eos( ztsn, zrhd, fsdept_n(:,:,:) )                       ! now in situ density using initial salinity
         !
         zbotpres(:,:) = 0._wp                        ! no atmospheric surface pressure, levitating sea-ice
         DO jk = 1, jpkm1
            zbotpres(:,:) = zbotpres(:,:) + fse3t(:,:,jk) * zrhd(:,:,jk)
         END DO
         IF( .NOT.lk_vvl ) THEN
            IF ( ln_isfcav ) THEN
               DO ji=1,jpi
                  DO jj=1,jpj
                     zbotpres(ji,jj) = zbotpres(ji,jj) + sshn(ji,jj) * zrhd(ji,jj,mikt(ji,jj)) + riceload(ji,jj)
                  END DO
               END DO
            ELSE
               zbotpres(:,:) = zbotpres(:,:) + sshn(:,:) * zrhd(:,:,1)
            END IF
         END IF
      !                                         
         zarho = SUM( area(:,:) * zbotpres(:,:) ) 
         IF( lk_mpp )   CALL mpp_sum( zarho )
         zssh_steric = - zarho / area_tot
         CALL iom_put( 'sshthster', zssh_steric )
      ENDIF
#endif
      !                                         ! steric sea surface height
      CALL eos( tsn, zrhd, zrhop, fsdept_n(:,:,:) )                 ! now in situ and potential density
      zrhop(:,:,jpk) = 0._wp
      CALL iom_put( 'rhop', zrhop )
      !
      zbotpres(:,:) = 0._wp                        ! no atmospheric surface pressure, levitating sea-ice
      DO jk = 1, jpkm1
         zbotpres(:,:) = zbotpres(:,:) + fse3t(:,:,jk) * zrhd(:,:,jk)
      END DO
      IF( .NOT.lk_vvl ) THEN
         IF ( ln_isfcav ) THEN
            DO ji=1,jpi
               DO jj=1,jpj
                  zbotpres(ji,jj) = zbotpres(ji,jj) + sshn(ji,jj) * zrhd(ji,jj,mikt(ji,jj)) + riceload(ji,jj)
               END DO
            END DO
         ELSE
            zbotpres(:,:) = zbotpres(:,:) + sshn(:,:) * zrhd(:,:,1)
         END IF
      END IF
      !    
#if !defined key_botpreonly
      zarho = SUM( area(:,:) * zbotpres(:,:) ) 
      IF( lk_mpp )   CALL mpp_sum( zarho )
      zssh_steric = - zarho / area_tot
      CALL iom_put( 'sshsteric', zssh_steric )
#endif
      
      !                                         ! ocean bottom pressure
      zztmp = rau0 * grav * 1.e-4_wp               ! recover pressure from pressure anomaly and cover to dbar = 1.e4 Pa
      zbotpres(:,:) = zztmp * ( zbotpres(:,:) + sshn(:,:) + thick0(:,:) )
      CALL iom_put( 'botpres', zbotpres )

#if !defined key_botpreonly
      !                                         ! Mean density anomalie, temperature and salinity
      ztemp = 0._wp
      zsal  = 0._wp
      DO jk = 1, jpkm1
         DO jj = 1, jpj
            DO ji = 1, jpi
               zztmp = area(ji,jj) * fse3t(ji,jj,jk)
               ztemp = ztemp + zztmp * tsn(ji,jj,jk,jp_tem)
               zsal  = zsal  + zztmp * tsn(ji,jj,jk,jp_sal)
            END DO
         END DO
      END DO
      IF( .NOT.lk_vvl ) THEN
         IF ( ln_isfcav ) THEN
            DO ji=1,jpi
               DO jj=1,jpj
                  ztemp = ztemp + zarea_ssh(ji,jj) * tsn(ji,jj,mikt(ji,jj),jp_tem) 
                  zsal  = zsal  + zarea_ssh(ji,jj) * tsn(ji,jj,mikt(ji,jj),jp_sal) 
               END DO
            END DO
         ELSE
            ztemp = ztemp + SUM( zarea_ssh(:,:) * tsn(:,:,1,jp_tem) )
            zsal  = zsal  + SUM( zarea_ssh(:,:) * tsn(:,:,1,jp_sal) )
         END IF
      ENDIF
      IF( lk_mpp ) THEN  
         CALL mpp_sum( ztemp )
         CALL mpp_sum( zsal  )
      END IF
      !
      zmass = rau0 * ( zarho + zvol )                 ! total mass of liquid seawater
      ztemp = ztemp / zvol                            ! potential temperature in liquid seawater
      zsal  = zsal  / zvol                            ! Salinity of liquid seawater
      !
      CALL iom_put( 'masstot', zmass )
      CALL iom_put( 'temptot', ztemp )
      CALL iom_put( 'saltot' , zsal  )

      IF( iom_use( 'tnpeo' )) THEN    
      ! Work done against stratification by vertical mixing
      ! Exclude points where rn2 is negative as convection kicks in here and
      ! work is not being done against stratification
         zpe(:,:) = 0._wp
         IF( lk_zdfddm ) THEN
            DO jk = 2, jpk
               DO jj = 1, jpj
                  DO ji = 1, jpi
                     IF( rn2(ji,jj,jk) > 0._wp ) THEN
                        zrw =   ( fsdepw(ji,jj,jk  ) - fsdept(ji,jj,jk) )   &
                           &  / ( fsdept(ji,jj,jk-1) - fsdept(ji,jj,jk) )
                        !
                        zaw = rab_n(ji,jj,jk,jp_tem) * (1. - zrw) + rab_n(ji,jj,jk-1,jp_tem)* zrw
                        zbw = rab_n(ji,jj,jk,jp_sal) * (1. - zrw) + rab_n(ji,jj,jk-1,jp_sal)* zrw
                        !
                        zpe(ji, jj) = zpe(ji, jj)            &
                           &        -  grav * (    avt(ji,jj,jk) * zaw * (tsn(ji,jj,jk-1,jp_tem) - tsn(ji,jj,jk,jp_tem) )  &
                           &                   - fsavs(ji,jj,jk) * zbw * (tsn(ji,jj,jk-1,jp_sal) - tsn(ji,jj,jk,jp_sal) ) )
                     ENDIF
                  END DO
               END DO
             END DO
          ELSE
            DO jk = 1, jpk
               DO ji = 1, jpi
                  DO jj = 1, jpj
                     zpe(ji,jj) = zpe(ji,jj) + avt(ji, jj, jk) * MIN(0._wp,rn2(ji, jj, jk)) * rau0 * fse3w(ji, jj, jk)
                  END DO
               END DO
            END DO
         ENDIF
         CALL lbc_lnk(zpe, 'T', 1._wp)         
         CALL iom_put( 'tnpeo', zpe  )
      ENDIF
      !
      CALL wrk_dealloc( jpi , jpj              , zarea_ssh , zbotpres, zpe )
      CALL wrk_dealloc( jpi , jpj , jpk        , zrhd      , zrhop         )
      CALL wrk_dealloc( jpi , jpj , jpk , jpts , ztsn                      )
#else
      CALL wrk_dealloc( jpi , jpj              , zbotpres                  )
      CALL wrk_dealloc( jpi , jpj , jpk        , zrhd      , zrhop         )
#endif
      !
      IF( nn_timing == 1 )   CALL timing_stop('dia_ar5')
      !
   END SUBROUTINE dia_ar5


   SUBROUTINE dia_ar5_init
      !!----------------------------------------------------------------------
      !!                  ***  ROUTINE dia_ar5_init  ***
      !!                   
      !! ** Purpose :   initialization for AR5 diagnostic computation
      !!----------------------------------------------------------------------
      INTEGER  ::   inum
      INTEGER  ::   ik
      INTEGER  ::   ji, jj, jk  ! dummy loop indices
      REAL(wp) ::   zztmp  
      REAL(wp), POINTER, DIMENSION(:,:,:,:) ::   zsaldta   ! Jan/Dec levitus salinity
      !
      !!----------------------------------------------------------------------
      !
      IF( nn_timing == 1 )   CALL timing_start('dia_ar5_init')
      !
      !                                      ! allocate dia_ar5 arrays
      IF( dia_ar5_alloc() /= 0 )   CALL ctl_stop( 'STOP', 'dia_ar5_init : unable to allocate arrays' )

#if !defined key_botpreonly
      CALL wrk_alloc( jpi, jpj, jpk, 2, zsaldta )
      area(:,:) = e1t(:,:) * e2t(:,:) * tmask_i(:,:)

      area_tot = SUM( area(:,:) )   ;   IF( lk_mpp )   CALL mpp_sum( area_tot )

      vol0        = 0._wp
#endif
      thick0(:,:) = 0._wp
      DO jk = 1, jpkm1
#if !defined key_botpreonly
         vol0        = vol0        + SUM( area (:,:) * tmask(:,:,jk) * e3t_0(:,:,jk) )
#endif
         thick0(:,:) = thick0(:,:) +    tmask_i(:,:) * tmask(:,:,jk) * e3t_0(:,:,jk)
      END DO

#if !defined key_botpreonly
      IF( lk_mpp )   CALL mpp_sum( vol0 )

      IF( iom_use('sshthster')) THEN
         CALL iom_open ( 'sali_ref_clim_monthly', inum )
         CALL iom_get  ( inum, jpdom_data, 'vosaline' , zsaldta(:,:,:,1), 1  )
         CALL iom_get  ( inum, jpdom_data, 'vosaline' , zsaldta(:,:,:,2), 12 )
         CALL iom_close( inum )

         sn0(:,:,:) = 0.5_wp * ( zsaldta(:,:,:,1) + zsaldta(:,:,:,2) )        
         sn0(:,:,:) = sn0(:,:,:) * tmask(:,:,:)
         IF( ln_zps ) THEN               ! z-coord. partial steps
            DO jj = 1, jpj               ! interpolation of salinity at the last ocean level (i.e. the partial step)
               DO ji = 1, jpi
                  ik = mbkt(ji,jj)
                  IF( ik > 1 ) THEN
                     zztmp = ( gdept_1d(ik) - gdept_0(ji,jj,ik) ) / ( gdept_1d(ik) - gdept_1d(ik-1) )
                     sn0(ji,jj,ik) = ( 1._wp - zztmp ) * sn0(ji,jj,ik) + zztmp * sn0(ji,jj,ik-1)
                  ENDIF
               END DO
            END DO
         ENDIF
      ENDIF
      !
      CALL wrk_dealloc( jpi, jpj, jpk, 2, zsaldta )
#endif
      !
      IF( nn_timing == 1 )   CALL timing_stop('dia_ar5_init')
      !
   END SUBROUTINE dia_ar5_init

#else
   !!----------------------------------------------------------------------
   !!   Default option :                                         NO diaar5
   !!----------------------------------------------------------------------
   LOGICAL, PUBLIC, PARAMETER :: lk_diaar5 = .FALSE.   ! coupled flag
CONTAINS
   SUBROUTINE dia_ar5_init    ! Dummy routine
   END SUBROUTINE dia_ar5_init
   SUBROUTINE dia_ar5( kt )   ! Empty routine
      INTEGER ::   kt
      WRITE(*,*) 'dia_ar5: You should not have seen this print! error?', kt
   END SUBROUTINE dia_ar5
#endif

   !!======================================================================
END MODULE diaar5
