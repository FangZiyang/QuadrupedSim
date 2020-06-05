load('quad_opt_output_6', 'opt_state_init', 'opt_state_soln','robot_state1', 'robot_state2');
addpath('../CasADi')
import casadi.*

load('casadi_state_derive_quad','casadi_sx_com_angle_func',...
                                'casadi_sx_com_pos_func',...
                                'casadi_sx_com_angle_vel_func',...
                                'casadi_sx_com_vel_func',...
                                'casadi_sx_list_force_func',...
                                'casadi_sx_list_swing_pos_func',...
                                'casadi_sx_list_swing_vel_func',...
                                'casadi_sx_list_swing_acc_func'); 
% calculate necessary start and end pos and force 
% the actual pos of p_e and com_pos need to add this reference value to
% scale back
sp = TransitionStateProcessor(quad_param);

com_pos_start = robot_state1(1:3);
com_pos_end = robot_state2(1:3);
com_ang_start = robot_state1(4:6);
com_ang_end = robot_state2(4:6);
p_e_start = quad_optimal_transition_get_foot_pos_from_state(robot_state1, quad_param);
p_e_end = quad_optimal_transition_get_foot_pos_from_state(robot_state2, quad_param);
F_e_start = quad_optimal_transition_get_foot_force_from_state(robot_state1, quad_param);
F_e_end = quad_optimal_transition_get_foot_force_from_state(robot_state2, quad_param);

%% intepolate to get reference trajectories
t_list = 0:quad_param.dt:quad_param.total_time;  
if (t_list(end) ~= quad_param.total_time)
    t_list = [t_list quad_param.total_time];
end
com_pos_list = zeros(3,size(t_list,2));
com_angle_list = zeros(3,size(t_list,2));
com_vel_list = zeros(3,size(t_list,2));
com_angle_vel_list = zeros(3,size(t_list,2));
foot_pos_list = zeros(quad_param.leg_num,3,size(t_list,2)); 
foot_vel_list = zeros(quad_param.leg_num,3,size(t_list,2)); 
foot_acc_list = zeros(quad_param.leg_num,3,size(t_list,2)); 
foot_force_list = zeros(quad_param.leg_num,3,size(t_list,2)); 

% contact 1 is stance, contact 0 is swing
contact_list = zeros(quad_param.leg_num,size(t_list,2));

for i=1:size(t_list,2)
    cur_time = t_list(i);
    angle_val = casadi_sx_com_angle_func(cur_time, opt_state_soln, com_ang_start, com_ang_end);
    com_angle_list(:,i) = full(angle_val);
    angle_vel_val = casadi_sx_com_angle_vel_func(cur_time, opt_state_soln, com_ang_start, com_ang_end);
    com_angle_vel_list(:,i) = full(angle_vel_val);
    
    com_pos_val = casadi_sx_com_pos_func(cur_time, opt_state_soln, com_pos_start, com_pos_end);
    com_pos_list(:,i) = full(com_pos_val) + ref_com_pos_start;
    com_vel_val = casadi_sx_com_vel_func(cur_time, opt_state_soln, com_pos_start, com_pos_end);
    com_vel_list(:,i) = full(com_vel_val);
    
    for j = 1:quad_param.leg_num
        foot_pos_val = casadi_sx_list_swing_pos_func{j}(cur_time, opt_state_soln, p_e_start(:,j), p_e_end(:,j));
        foot_pos_list(j,:,i) = full(foot_pos_val) + ref_com_pos_start;
        
        foot_vel_val = casadi_sx_list_swing_vel_func{j}(cur_time, opt_state_soln, p_e_start(:,j), p_e_end(:,j));
        foot_vel_list(j,:,i) = full(foot_vel_val);
        
        foot_acc_val = casadi_sx_list_swing_acc_func{j}(cur_time, opt_state_soln, p_e_start(:,j), p_e_end(:,j));
        foot_acc_list(j,:,i) = full(foot_acc_val);
        
%         contact list from the phase time of the solution 
        phase_time = sp.getPhaseTime(opt_state_soln,j,1);
        if ((cur_time < phase_time(1)) || (cur_time >= phase_time(2)))
            contact_list(j,i) = 1;
        else
            contact_list(j,i) = 0;
        end
    end
    % force is more complicated
    for j = 1:quad_param.leg_num
        foot_force_val = casadi_sx_list_force_func{j}(cur_time, opt_state_soln, F_e_start(:,j), F_e_end(:,j));
        foot_force_list(j,:,i) = full(foot_force_val)*quad_param.force_scale;
    end
end

%% test LQR
% x_0 use t= 0
init_foot_pos = zeros(3,quad_param.leg_num);
for i=1:quad_param.leg_num
    init_foot_pos(:,i) = foot_pos_list(i,:,1);  
end
x_0 = [com_pos_list(:,1); ...
             com_angle_list(:,1);...
             [0;0;0];[0;0;0];...
             reshape(init_foot_pos,3*quad_param.leg_num,1)];


% x_d_final uses t = T
init_foot_pos = zeros(3,quad_param.leg_num);
for i=1:quad_param.leg_num
    init_foot_pos(:,i) = foot_pos_list(i,:,end);
    
end
x_d_final = [com_pos_list(:,end); ...
             com_angle_list(:,end);...
             [0;0;0];[0;0;0];...
             reshape(init_foot_pos,3*quad_param.leg_num,1)];
   
% euler integration    
x = x_0;
for i=1:size(t_list,2)
    
    curr_foot_force = zeros(3,quad_param.leg_num);
    for j=1:quad_param.leg_num
        curr_foot_force(:,j) = foot_force_list(j,:,i);
    end
    curr_foot_vel = zeros(3,quad_param.leg_num);
    for j=1:quad_param.leg_num
        curr_foot_vel(:,j) = foot_vel_list(j,:,i);
    end
    curr_u = [reshape(curr_foot_force,3*quad_param.leg_num,1);...
              reshape(curr_foot_vel,3*quad_param.leg_num,1)];
 
%     % test w_c_dot
%     roll_ang  = x(4);
%     pitch_ang = x(5);
%     yaw_ang   = x(6);
%     R_ec =   [ cos(yaw_ang)  -sin(yaw_ang)    0;
%                sin(yaw_ang)   cos(yaw_ang)    0;
%                          0               0    1]*...
%              [cos(pitch_ang) 0 sin(pitch_ang);
%                            0 1              0;
%              -sin(pitch_ang) 0 cos(pitch_ang)]*...
%              [         1              0              0;
%                        0  cos(roll_ang) -sin(roll_ang);
%                        0  sin(roll_ang)  cos(roll_ang)];
%     com_w_c = x(10:12);
%     foot_pos = x(13:end);
%     F_e = reshape(curr_foot_force,3*quad_param.leg_num,1);
%     com_pos_e = x(1:3);
%     I = quad_param.body_inertia;
%     w_acc = -VecToso3(com_w_c)*I*com_w_c;
%     for j = 1:quad_param.leg_num
%     % no dynamics yet
%         swing_dynamics = VecToso3(quad_param.t_cs(:,j))*R_ec'*[0;0;(quad_param.upper_leg_mass+quad_param.lower_leg_mass)*-quad_param.g];
%         p_c = R_ec'*(foot_pos((j-1)*3+1:(j-1)*3+3) - com_pos_e);
%         w_acc = w_acc + swing_dynamics*(1-contact_list(j,i)) + contact_list(j,i)*VecToso3(p_c)*R_ec'*F_e((j-1)*3+1:(j-1)*3+3);
%     end
%     com_w_c_dot = inv(I)*(w_acc); 
          
          
    xdot = casadi_quad_LQR_f_func_code('quad_LQR_f_func',x,curr_u, contact_list(:,i));  
    A = casadi_quad_LQR_A_func_code('quad_LQR_A_func',x,curr_u, contact_list(:,i));  
    B = casadi_quad_LQR_B_func_code('quad_LQR_B_func',x,curr_u, contact_list(:,i));  
    xdot_l = A*x + B*curr_u;
    xdot(xdot>3) = 3;
    xdot(xdot<-3) = -3;
    xdot_l(xdot_l>3) = 3;
    xdot_l(xdot_l<-3) = -3;
    x = x + xdot_l*quad_param.dt;
end

%% first define step between start time and end time
t = 1.2; T= quad_param.total_time;
step = (T-t)/quad_param.dt;
% a different runtime_t_list is used during LQR
runtime_t_list = (0:step)*quad_param.dt+t;
if (runtime_t_list(end) ~= quad_param.total_time)
    runtime_t_list = [runtime_t_list quad_param.total_time];
end

%% initial state at t should come from feedback, here for testing we just use the first x_d
curr_com_pos = interp1(t_list,com_pos_list', t)';
curr_com_vel = interp1(t_list,com_vel_list', t)';
curr_com_angle = interp1(t_list,com_angle_list', t)';
curr_com_angle_vel = interp1(t_list,com_angle_vel_list', t)';
curr_foot_pos = zeros(3,quad_param.leg_num);
for i=1:quad_param.leg_num
    curr_foot_pos(:,i) = interp1(t_list,squeeze(foot_pos_list(i,:,:))', t)';
end
x_0 = [curr_com_pos; curr_com_angle;...
       curr_com_vel; curr_com_angle_vel;...
             reshape(curr_foot_pos,3*quad_param.leg_num,1)];
%% forward pass, save x xd ud and A B 
x = x_0;
x_list = zeros(size(x_0,1),size(runtime_t_list,2));
xd_list = zeros(size(x_0,1),size(runtime_t_list,2));
ud_list = zeros(size(x_0,1),size(runtime_t_list,2));
A_list = zeros(quad_param.size_x, quad_param.size_x, size(runtime_t_list,2));
B_list = zeros(quad_param.size_x, quad_param.size_u, size(runtime_t_list,2));
for i=1:size(runtime_t_list,2)
    curr_t = runtime_t_list(i);
    % get current u_d
    curr_foot_force = zeros(3,quad_param.leg_num);
    for j=1:quad_param.leg_num
        curr_foot_force(:,j) = interp1(t_list,squeeze(foot_force_list(j,:,:))', curr_t)';
    end
    curr_foot_vel = zeros(3,quad_param.leg_num);
    for j=1:quad_param.leg_num
        curr_foot_vel(:,j) = interp1(t_list,squeeze(foot_vel_list(j,:,:))', curr_t)';
    end
    u_d = [reshape(curr_foot_force,3*quad_param.leg_num,1);...
              reshape(curr_foot_vel,3*quad_param.leg_num,1)];
    
    % get current x_d
    curr_com_pos = interp1(t_list,com_pos_list', curr_t)';
    curr_com_vel = interp1(t_list,com_vel_list', curr_t)';
    curr_com_angle = interp1(t_list,com_angle_list', curr_t)';
    curr_com_angle_vel = interp1(t_list,com_angle_vel_list', curr_t)';
    curr_foot_pos = zeros(3,quad_param.leg_num);
    for j=1:quad_param.leg_num
        curr_foot_pos(:,j) = interp1(t_list,squeeze(foot_pos_list(j,:,:))', curr_t)';
    end
    x_d = [curr_com_pos; curr_com_angle;...
           curr_com_vel; curr_com_angle_vel;...
                 reshape(curr_foot_pos,3*quad_param.leg_num,1)];    
    
    contact = interp1(t_list,contact_list', curr_t)';
    x_list(:,i) = x;    
    xd_list(:,i) = x_d;    
    ud_list(:,i) = u_d;         
    A_list(:,:,i) = casadi_quad_LQR_A_func_code('quad_LQR_A_func',x,u_d, contact);
    B_list(:,:,i) = casadi_quad_LQR_B_func_code('quad_LQR_B_func',x,u_d, contact);
    if (i ~= size(runtime_t_list,2))
        xdot = casadi_quad_LQR_f_func_code('quad_LQR_f_func',x,u_d, contact);  
        xdot(xdot>1) = 1;
        xdot(xdot<-1) = -1;        
        x = x + xdot*quad_param.dt;    
    end
end

%% backward pass
Q = 0.001*eye(quad_param.size_x); Qf = 0.001*Q;
R  = 0.001*eye(quad_param.size_u); Rinv = inv(R);
Sxx = Qf;
sx  = -Qf*xd_list(:,end);
for i = size(runtime_t_list,2):-1:2
    i
    A = A_list(:,:,i);
    B = B_list(:,:,i);
    dSxx = Q-Sxx*B*Rinv*B'*Sxx + Sxx*A + A'*Sxx;
    dsx  = -2*Q*xd_list(:,i) + (A'-Sxx*B*Rinv*B')*sx + 2*Sxx*B*ud_list(:,i);
    Sxx = Sxx + dSxx*quad_param.dt;  
    sx  = sx  + dsx*quad_param.dt;  
end
ut = ud_list(:,1) - Rinv*B_list(:,:,1)*(Sxx*x_0+0.5*sx);

% com_pos_list = zeros(3,size(t_list,2));
% com_angle_list = zeros(3,size(t_list,2));
% com_vel_list = zeros(3,size(t_list,2));
% com_angle_vel_list = zeros(3,size(t_list,2));
% foot_pos_list = zeros(quad_param.leg_num,3,size(t_list,2)); 
% foot_vel_list = zeros(quad_param.leg_num,3,size(t_list,2)); 
% foot_acc_list = zeros(quad_param.leg_num,3,size(t_list,2)); 
    % foot_force_list = zeros(quad_param.leg_num,3,size(t_list,2)); 