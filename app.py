import os #Import the OS module, nececary for python interaction with the operating system.
import subprocess #Import the subproccess module which allows for python to run other programs or commands.
import shutil
import time # Import the time functionality which is used to print crashlogs. 
import threading # Threading is used later in the program to check if libreoffice is running or not.
from flask import Flask, render_template, request, redirect, url_for # Import some extra Flask tools for displaying the pages. 
from flask_login import LoginManager, UserMixin, login_user, login_required #Import the flask login tools. The login manager handles the logging in and logging out of users. It also handles managing user sessions and the ability to lock certain pages unless logged in.
from datetime import datetime # Import datetime functionality which is used to log crashes.

app = Flask(__name__)
app.config['SECRET_KEY'] = 'eyfbdh!3dh#@hHbVVy1' # Sets a secret key which is used by flask to sign cookies.
app.config['UPLOAD_FOLDER'] = 'uploads/' # Define the location of the uploads folder.
login_manager = LoginManager(app) # Create an instance of login manager and set it to the variable login_manager. 
login_manager.login_view = 'login' # Stops the user from getting a 404 error when navigating to the uploads page without being logged in.

class User(UserMixin): # This class handles the storage of user ID as well as providing a way of retrieving that data when nececeary.
    def __init__(self, id):
        self.id = id
    def get_id(self): 
        return str(self.id) 

@login_manager.user_loader # If the user is logged in then allow them to access the website.
def load_user(user_id):  
    if user_id == '1': 
        return User(1) 
    return None

if not os.path.exists(app.config['UPLOAD_FOLDER']): # Checks to see if the upload folder exists and if it does not create one.
    os.makedirs(app.config['UPLOAD_FOLDER'])

def clear_uploads():# Handles deletion of old files in the uploads folder. 
    upload_folder = app.config['UPLOAD_FOLDER']# Sets the location of the upload folder directory to the flask UPLOAD_FOLDER location.
    for filename in os.listdir(upload_folder): # Goes through all the files in the uploads folder.
        file_path = os.path.join(upload_folder, filename) # Creates the path for each of the files in the uploads folder.
        try: 
            if os.path.isfile(file_path) or os.path.islink(file_path): # Check if the file is actually a file and not a link to another file.
                os.unlink(file_path) # Unlinks the file, thus deleting it.
            elif os.path.isdir(file_path):# If the item is a directory rather than a file it deletes the entire directory and it's contents.
                shutil.rmtree(file_path) 
        except Exception as e:# If there is an error print a message to the terminal with the specific file and error.
            print('Unable to remove %s. Because: %s' % (file_path, e)) 

def run_presentation():# Function handles running the presentation and will be called whenever the powerpoint crashes or a new one is uploaded.
    upload_folder = app.config['UPLOAD_FOLDER']# Get the location of the uploads folder from the flask configuration.
    for filename in os.listdir(upload_folder): # For loop to check the names of the files in the uploads folder.
        if filename.lower().endswith(('.ppt', '.pptx')):#Checks to make sure that the file is a pptx or ppt file.
            file_path = os.path.join(upload_folder, filename)
            subprocess.call(['pkill', '-f', 'libreoffice'])# Kills the current libreoffice instance.
            subprocess.Popen(['libreoffice', '--show', file_path]) # opens libreoffice and the powerpoint in show mode.
            break

def is_libreoffice_running():# Function to check if libreoffice is running.
    try:
        subprocess.check_output(['pgrep', '-f', 'libreoffice'])# Run a command to check if libreoffice is running.
        return True # Return true if libreoffice is running.
    except subprocess.CalledProcessError: # If the libreoffice is not running then return false.
        return False
    
def log_crash(): # Tells the program what to print when an error occurs.
    now = datetime.now()# Sets the now variable to contain the current hour miniute and second.
    current_time = now.strftime("%H :%M :%S")# Sets the the current_time variable to the contents of now and tells it how it should display the hour, minute and second.
    print("Presentation crashed or was closed at: " + current_time + " Relaunching...")# Prints to the terminal that libreoffice closed, and been relaunched.

def crash_protection(): # Function used to check if the power point has crashed. If it has it is relaunched.
    while True: # While LibreOffice is not running then do the following.
        if not is_libreoffice_running():# If the "is_libreoffice_running" function returns false then execute this function.
            log_crash() # Run the log_crash function.
            run_presentation() # Run the run_presentation function.
        time.sleep(5)  # Rerun the function every 5 seconds to minimise downtime.

@app.route('/', methods=['GET', 'POST']) # Specifies the http methods that are avalible and when this function should trigger.
def login():# Function to handle logins.
    error = None 
    if request.method == 'POST': # If the flask app recives data from the form in the login page.
        if request.form['username'] == 'admin' and request.form['password'] == 'Library24!': # Compares what was submitted in the form to what the password should be. This is also where the password is set.
            user = User(1) # The user is set to 1 which will allow the login_user function to log the user in.
            login_user(user) # The login_user function is then used and given user as a variable.
            return redirect(url_for('upload_file')) # Redirects the user to the uploads page.
        else: # If the password and username don't match then report an error and render it in the login html page.
            error = 'Invalid credentials' 
    return render_template('login.html', error=error)

@app.route('/uploads', methods=['GET','POST'])# Routes the user to the uploads page.
@login_required # Ensures that the user must be logged in before navigating to this page. Were this not implemented someone would simply be able to add /uploads to the end of the URL and bypass the security.
def upload_file():# Handles uploading a file.
    if request.method == 'POST': # If the user uploads a file then do the following.
        clear_uploads() # Delete all previous files in the uploads folder.
        file = request.files['file'] # Retrieve the file that was submitted.
        file_path = os.path.join(app.config['UPLOAD_FOLDER'], file.filename) # Get the file path to the uploads folder. 
        file.save(file_path) # Save the file to the uploads folder.
        
        run_presentation() # Immediatly run the presentation.
        
        return 'File uploaded and displayed successfully! You may now close this page.' # Display that the file was uploaded successfully on the website.
    return render_template('upload.html')
    
@app.route("/changelog") # Locks this code behind the /changelog url.
def changelog():
    with open('changelog.txt', 'r') as file: # Opens the changelog.txt file in the root app folder in read mode under the name 'file'
        content = file.read() # Sets the content variable to be the content of the changelog.txt
    return render_template('changelog.html', content=content) # Render the html template and the content of the changelog.txt file.

if __name__ == '__main__':
    run_presentation()  # Run the presentation when the app starts
    
    # Start the background thread to check and relaunch the presentation
    check_thread = threading.Thread(target=crash_protection)
    check_thread.daemon = True
    check_thread.start()
    
    app.run(host='0.0.0.0')#Runs the app on the avalible host address.